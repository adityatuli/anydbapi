# This runs a simple sinatra app as a service
ANYDBAPI_DIR = File.expand_path(File.dirname(__FILE__))
LOG_FILE = "#{ANYDBAPI_DIR}\\daemon.log"

begin
  Dir.chdir(ANYDBAPI_DIR) do
    # $: << File.expand_path(File.dirname(__FILE__))
    require 'win32/daemon'
    require './anydbapi'
    include Win32

    class AnyDBAPIDaemon < Daemon
      def service_init
         File.open(LOG_FILE, 'a'){ |f| f.puts "Initializing service #{Time.now}" } 
      end

      def service_main
        AnydbAPI.set :environment => 'production'
        AnydbAPI.run! :host => 'localhost', :port => 9292, :server => 'mongrel'
        File.open(LOG_FILE, "a"){ |f| f.puts "Service is running #{Time.now}" }
        while running?
          sleep 10
        end
      end

      def service_stop
        File.open(LOG_FILE, "a"){ |f| f.puts "***Service stopped #{Time.now}" }
        #AnydbAPI.quit!
        exit!
      end
    end

    AnyDBAPIDaemon.mainloop
  end
rescue Exception => err
  File.open(LOG_FILE,'a+'){ |f| f.puts " ***Daemon failure #{Time.now} err=#{err} " }
  raise
end
