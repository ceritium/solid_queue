# Debug only: if a single test runs longer than HANG_WATCHDOG seconds, dump every
# thread's backtrace and exit, so CI hangs leave a trace instead of a timeout.
module HangWatchdog
  STATE = { name: nil, started_at: nil }

  def run
    STATE[:name] = "#{self.class}##{name}"
    STATE[:started_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  ensure
    STATE[:started_at] = nil
  end

  def self.dump(test)
    $stderr.puts "\n=== HANG WATCHDOG: #{test} exceeded #{LIMIT}s, pid #{::Process.pid}, #{Thread.list.size} threads"
    Thread.list.each do |thread|
      $stderr.puts "--- #{thread.inspect} status=#{thread.status.inspect}"
      (thread.backtrace || []).each { |line| $stderr.puts "    #{line}" }
    end
    $stderr.flush
  end

  LIMIT = Float(ENV.fetch("HANG_WATCHDOG", "90"))
end

Minitest::Test.prepend(HangWatchdog)

Thread.new do
  owner = ::Process.pid
  loop do
    sleep [ HangWatchdog::LIMIT / 4, 5 ].min
    next unless ::Process.pid == owner
    started_at, test = HangWatchdog::STATE.values_at(:started_at, :name)
    if started_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at > HangWatchdog::LIMIT
      HangWatchdog.dump(test)
      exit! 99
    end
  end
end
