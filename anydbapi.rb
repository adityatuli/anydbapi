# anydbapi.rb
# encoding: UTF-8
require 'rubygems' if RUBY_VERSION < '1.9'
require 'sinatra/base'
#require 'sinatra/synchrony'
require 'nokogiri'
require 'dbi'
require 'json'
require 'logger'
require 'base64'
#require 'benchmark'

class AnydbAPI < Sinatra::Base
  #register Sinatra::Synchrony

  helpers do
    # function to ping database connection
    #   returns true if connection is alive, else returns false
    def ping?(dbh)
      begin
        stmt = dbh.prepare("SELECT 1")
        answer = stmt.execute
        if answer
            return true
        else
          return false
        end
      rescue DBI::DatabaseError => e
        return false
      ensure
        stmt.finish
      end
    end  
  end
  # end of helper

  # function that returns a connection made using a connection node from the config xml
  def self.connectNode(node, name, log) 
    dbTypes = Hash['mysql' => 'dbi:Mysql', 'odbc' => 'dbi:ODBC']

    type = node.attr('type')
    
    log.debug("Attempting to connect to " + name + "...")

    child = node.at_xpath('./dsn')
    dsn = child ? child.text : ''
    child = node.at_xpath('./server')
    server = child ? child.text : ''
    child = node.at_xpath('./database')
    database = child ? child.text : ''       
    username = node.at_xpath('./username').text
    password = node.at_xpath('./password').text  
    
    dbh = DBI.connect('''' << dbTypes[type.downcase] << ':' << ((dsn != '') ? dsn : (database << ':' << server)) << '''', username, password) 
    log.info("Connected to " + name + ".")

    return dbh
  end

  configure do
    # start a logger
    f = File.open('anydbapi.log', 'a')
    f.sync = true
    log = Logger.new(f)
    log.level = Logger::INFO

    log.info("Attempting to start server on " + Time.now.strftime('%d-%m-%Y') + " at "  + Time.now.strftime('%H:%M:%S') + "...")

    connections = Hash.new
    functions = []
    
    # open the XML config file
    begin
    	f = File.open('config.xml')
    	doc = Nokogiri::XML(f)
    	set :configXML, doc
    	
      # get the connection list
    	connList = doc.xpath('//connections/connection')
      if (connList.length == 0) 
        log.error("No connections defined in config.xml.")
        exit
      else
        # found connections
        connList.each do |node|
          name = node.attr('name')
          dbh = self.connectNode(node, name, log)
          connections[name] = dbh
        end
        set :connections, connections

        # get the function list
        functionList = doc.xpath('//functions/function')
        if (functionList.length == 0)
          log.warn("No function definitions found. Define some functions in config.xml.")
        else
          # found functions
          functionList.each do |node|
            name = node.attr('name')
            functions << name
          end    
        end
        set :functions, functions

        # get chunk size
        child = doc.at_xpath("//settings/chunksize")
        chunkSize = child ? child.text.to_i : 500
        set :chunkSize, chunkSize

        log.info("Server started ok.")

        set :log, log
        #set :environment, :production
      end
    	
  	rescue SystemExit
      log.info("Shutting down.")
      abort("Shutting down unexpectedly! Check the log for details.")
    rescue DBI::DatabaseError => e
      log.error(e.errstr)
  	  raise
    rescue Exception => e 
      log.fatal(e)
      raise
	  ensure
	    f.close unless f.nil?
    end
  end

  configure :development, :test do
    #only executes this code when environment is equal to one of the passed arguments
    log.level = Logger::DEBUG
  end
  
  # helpers do
  #   def valid_key? (key)
  #     return key != "abc" ? false : true
  #   end 
  # end

  # handle server close 
  at_exit do
    unless log.nil? 
      log.info("Server shutdown. Goodbye.")
    end
  end

  # 404 handler
  not_found do
    log = settings.log
    log.error(request.request_method + " request for " + request.url + " from " + request.ip + ".")
    error 404
  end

  # route '/'
  get '/' do
    #error 401 unless valid_key?(params[:key])
    "Welcome to the Any Database API service. Please contact Stellarise Ltd for instructions on using this service." 
  end

  # route '/functions/:name/execute'
  post '/functions/:name/execute' do 
    content_type :json

    stream(:keep_open) {|out| 

      # get the name of the function requested
      name = params[:name]
      
      log = settings.log
      log.info("Incoming request for function '" + name + "' from " + request.ip + ".")
      
      # cannot proceed if the client does not accept json! Pass to other handlers
      unless request.accept? 'application/json'
        log.error("Client does not accept JSON response.")
        #halt 406, {"status" => "Error", "message" => "Return type is JSON but client does not accept this."}.to_json 
        out << {"status" => "Error", "message" => "Return type is JSON but client does not accept this."}.to_json << "\n"
      end

      begin
      # does function exist?
        functions = settings.functions  
        if functions.include? name
          if (request.content_type == "application/json")
            request.body.rewind
            requestBody = JSON.parse(request.body.read)
            log.debug(requestBody)

            # get function query
            doc = settings.configXML
            functionNode = doc.at_xpath("//functions/function[@name = '" + name + "']")
            child = functionNode.at_xpath("./query")
            query = child ? child.text : ''
            nullValue = "Null"

            # replace query parameters
            child = functionNode.at_xpath("./binaryparams")
            binaryParams = child ? child.text : ''
            binaryParams = binaryParams.split(',').map(&:strip)

            query.gsub!(/%[^%]{0,}%/i) {|match|
              if requestBody.keys.include?(match[1..-2])
                if binaryParams.include? match[1..-2]
                  Base64.decode64(requestBody[match[1..-2]])
                else
                  # convert to string and escape any quotes
                  requestBody[match[1..-2]].to_s.gsub(/'/, "''")
                end    
              else
                nullValue
              end
            } 
            # replace any 'Null's with Null
            query.gsub!(Regexp.new("'" + nullValue + "'", true)) {|match| nullValue}
            log.debug("Prepared query: " + query)
            
            # get connection
            child = functionNode.at_xpath("./connection")
            conn = child ? child.text : ''
            dbh = settings.connections[conn]

            # re-establish the connection if connection has dropped
            if !(ping?(dbh))
              log.info("Connection '" + conn + "' dropped. Re-establishing connection.")
              dbh = AnydbAPI.connectNode(doc.at_xpath("//connections/connection[@name = '" + conn + "']"), conn, log)
              settings.connections[conn] = dbh
            end

            # prepare query statement and execute
            log.info query
            stmt = dbh.prepare(query)
            stmt.execute

            # to prepare data from result set...
            # 1. get encoding
            connNode = doc.at_xpath("//connections/connection[@name = '" + conn + "']")
            child = connNode.at_xpath("./encoding")
            encd = child ? child.text.upcase : 'UTF-8'

            # 2. get any expected binary fields in data
            child = functionNode.at_xpath("./binaryfields")
            binaryFields = child ? child.text : ''
            binaryFields = binaryFields.split(',').map(&:strip)
            
            # 3. start preparing an array of hash of all row data
            rows = []
            count = 0
            #Benchmark.bm do |x|
            #  x.report("hash time: ") {
              stmt.fetch_hash do |row| 
                #  Base64 encode all binary fields
                binaryFields.each {|binaryField|
                  if row[binaryField]
                    row[binaryField] = Base64.encode64(row[binaryField])
                  end 
                }

                # if encoding is not uft-8, encode the string values to utf-8 from orig encoding
                #   replace any invalid characters with ?
                if (encd != 'UTF-8')
                  row.select {|k, v| v.is_a? String}.each { |k, v| row[k] = v.encode("UTF-8", encd, :invalid => :replace, :undef => :replace, :replace => "?")}
                end

                rows << row
                if (count < settings.chunkSize) 
                  count = count + 1
                else
                  out << rows.to_json << "\n"
                  count = 0
                  rows.clear
                end  

              #rows << row
              #out << row.to_json << "\n"
              end # end of fetch_hash
            #} 

            out << rows.to_json << "\n" unless rows.empty?
            #end # end of benchmark

            stmt.finish
            log.debug("Finished handling request for function '" + name + "'.")
            #halt 200, rows.to_json
          else
            log.warn("Request content is not of type JSON. Cannot execute.")
            out << {"status" => "Error", "message" => "Request content needs to be JSON."}.to_json << "\n"
           end
        else
          log.error("Function '" + name + "' is not defined in config.xml.")
          out << {"status" => "Error", "message" => "Function '" + name + "' not found!"}.to_json << "\n"
        end
          
      rescue DBI::DatabaseError => e
        log.error(e.errstr)
        out << {"status" => "Error", "message" => e.errstr}.to_json << "\n"
        #raise
      rescue Exception => e 
        log.error(e.message)
        #halt 500, {"status" => "Error", "message" => e.message}.to_json
        out << {"status" => "Error", "message" => e.message}.to_json << "\n"
      end
    } # end of stream
  end

  # start the server if ruby file executed directly
  #run! if app_file == $0
end