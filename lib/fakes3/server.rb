require 'webrick'
require 'fakes3/file_store'
require 'fakes3/xml_adapter'

module FakeS3
  class Request
    CREATE_BUCKET = "CREATE_BUCKET"
    LIST_BUCKETS = "LIST_BUCKETS"
    LS_BUCKET = "LS_BUCKET"
    STORE = "STORE"
    COPY = "COPY"
    GET = "GET"
    GET_ACL = "GET_ACL"
    SET_ACL = "SET_ACL"
    MOVE = "MOVE"
    DELETE = "DELETE"

    attr_accessor :bucket,:object,:type,:src_bucket,:src_object,:method,:webrick_request,:path,:is_path_style

    def inspect
      puts "-----Inspect FakeS3 Request"
      puts "Type: #{@type}"
      puts "Is Path Style: #{@is_path_style}"
      puts "Request Method: #{@method}"
      puts "Bucket: #{@bucket}"
      puts "Object: #{@object}"
      puts "Src Bucket: #{@src_bucket}"
      puts "Src Object: #{@src_object}"
      puts "-----Done"
    end
  end

  class Servlet < WEBrick::HTTPServlet::AbstractServlet
    def initialize(server,store,hostname)
      super(server)
      @store = store
      @hostname = hostname
      @root_hostnames = [hostname,'localhost','s3.amazonaws.com','s3.localhost']
    end

    def do_GET(request, response)
      s_req = normalize_request(request)

      case s_req.type
      when 'LIST_BUCKETS'
        response.status = 200
        response['Content-Type'] = 'application/xml'
        buckets = @store.buckets
        response.body = XmlAdapter.buckets(buckets)
      when 'LS_BUCKET'
        bucket_obj = @store.get_bucket(s_req.bucket)
        if bucket_obj
          response.status = 200
          response.body = XmlAdapter.bucket(bucket_obj)
          response['Content-Type'] = "application/xml"
        else
          response.status = 404
          response.body = XmlAdapter.error_no_such_bucket(s_req.bucket)
          response['Content-Type'] = "application/xml"
        end
      when 'GET_ACL'
        response.status = 200
        response.body = XmlAdapter.acl()
        response['Content-Type'] = 'application/xml'
      when 'GET'
        real_obj = @store.get_object(s_req.bucket,s_req.object,request)
        if !real_obj
          response.status = 404
          response.body = ""
          return
        end

        response.status = 200
        response['Content-Type'] = real_obj.content_type
        content_length = File::Stat.new(real_obj.io.path).size
        response['Etag'] = real_obj.md5
        response['Accept-Ranges'] = "bytes"

        # Added Range Query support
        if range = request.header["range"].first
          response.status = 206
          if range =~ /bytes=(\d*)-(\d*)/
            start = $1.to_i
            finish = $2.to_i
            finish_str = ""
            if finish == 0
              finish = content_length - 1
              finish_str = "#{finish}"
            else
              finish_str = finish.to_s
            end

            bytes_to_read = finish - start + 1
            response['Content-Range'] = "bytes #{start}-#{finish_str}/#{content_length}"
            real_obj.io.pos = start
            response.body = real_obj.io.read(bytes_to_read)
            return
          end
        end
        response['Content-Length'] = File::Stat.new(real_obj.io.path).size
        response.body = real_obj.io
      end
    end

    def do_PUT(request,response)
      s_req = normalize_request(request)


      case s_req.type
      when Request::COPY
        @store.copy_object(s_req.src_bucket,s_req.src_object,s_req.bucket,s_req.object)
      when Request::STORE
        real_obj = @store.store_object(s_req.bucket,s_req.object,s_req.webrick_request)
        response['Etag'] = real_obj.md5
      when Request::CREATE_BUCKET
        @store.create_bucket(s_req.bucket)
      end

      response.status = 200
      response.body = ""
      response['Content-Type'] = "text/xml"
    end

    def do_POST(request,response)
      p request
    end

    def do_DELETE(request,response)
      p request
    end

    private

    def normalize_get(webrick_req,s_req)
      path = webrick_req.path
      path_len = path.size
      query = webrick_req.query
      if path == "/" and s_req.is_path_style
        s_req.type = Request::LIST_BUCKETS
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
        else
          elems = path.split("/")
        end

        if elems.size == 0
          # List buckets
          s_req.type = Request::LIST_BUCKETS
        elsif elems.size == 1
          s_req.type = Request::LS_BUCKET
        else
          if query["acl"] == ""
            s_req.type = Request::GET_ACL
          else
            s_req.type = Request::GET
          end
          object = elems[1,elems.size].join('/')
          s_req.object = object
        end
      end
    end

    def normalize_put(webrick_req,s_req)
      path = webrick_req.path
      path_len = path.size
      if path == "/"
        if s_req.bucket
          s_req.type = Request::CREATE_BUCKET
        end
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
          if elems.size == 1
            s_req.type = Request::CREATE_BUCKET
          else
            if webrick_req.request_line =~ /\?acl/
              s_req.type = Request::SET_ACL
            else
              s_req.type = Request::STORE
            end
            s_req.object = elems[1,elems.size].join('/')
          end
        else
          if webrick_req.request_line =~ /\?acl/
            s_req.type = Request::SET_ACL
          else
            s_req.type = Request::STORE
          end
          s_req.object = webrick_req.path
        end
      end

      copy_source = webrick_req.header["x-amz-copy-source"]
      if copy_source and copy_source.size == 1
        src_elems = copy_source.first.split("/")
        root_offset = src_elems[0] == "" ? 1 : 0
        s_req.src_bucket = src_elems[root_offset]
        s_req.src_object = src_elems[1 + root_offset,src_elems.size].join("/")
        s_req.type = Request::COPY
      end

      s_req.webrick_request = webrick_req
    end

    # This method takes a webrick request and generates a normalized FakeS3 request
    def normalize_request(webrick_req)
      host_header= webrick_req["Host"]
      host = host_header.split(':')[0]

      s_req = Request.new
      s_req.path = webrick_req.path
      s_req.is_path_style = true

      if !@root_hostnames.include?(host)
        s_req.bucket = host.split(".")[0]
        s_req.is_path_style = false
      end

      case webrick_req.request_method
      when 'PUT'
        normalize_put(webrick_req,s_req)
      when 'GET'
        normalize_get(webrick_req,s_req)
      else
        raise "Unknown Request"
      end

      return s_req
    end

    def dump_request(request)
      puts "----------Dump Request-------------"
      puts request.request_method
      puts request.path
      request.each do |k,v|
        puts "#{k}:#{v}"
      end
      puts "----------End Dump -------------"
    end
  end


  class Server
    def initialize(port,store,hostname)
      @port = port
      @store = store
      @hostname = hostname
    end

    def serve
      @server = WEBrick::HTTPServer.new(:Port => @port)
      @server.mount "/", Servlet, @store,@hostname
      trap "INT" do @server.shutdown end
      @server.start
    end

    def shutdown
      @server.shutdown
    end
  end
end