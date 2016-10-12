module Derby
  class FedoraAdapter    
    class Updater
      include Derby::Events
      
      attr :env, :status, :headers, :response
      def initialize(env,status,headers,response)
        @env = env
        @status = status
        @headers = headers
        @response = response
      end

      ##
      # Utility functions to aid in statement building and querying
      def subject ; response.graph.name   ; end      
      def graph   ; response.graph        ; end
      def fcrepo4 ; ::RDF::Vocab::Fcrepo4 ; end      
      def ldp     ; ::RDF::Vocab::LDP     ; end  

      ##
      # Ensure that the current subject asserts all of the given predicate/object pairs exactly once
      def ensure_all(pairs)
        pairs.each_pair do |predicate, object|
          statement = RDF::Statement(subject, predicate, object)
          graph << statement unless graph.has_statement?(statement)
        end
      end
      
      ##
      # Set the objects for the given predicates, deleting existing statements if necessary
      def replace(pairs)
        changes = RDF::Changeset.new do |c|
          pairs.each_pair do |predicate, object|
            RDF::Query::Pattern.new(subject, predicate, :value).execute(graph).each do |statement|
              c.delete statement
            end
            c.insert [subject, predicate, object]
          end
        end
        changes.apply(graph)
      end
      
      ##
      # Add fedora:created and fedora:createdBy
      def created!
        if status == 201
          replace fcrepo4.created => RDF::Literal::DateTime.new(Time.now.xmlschema), fcrepo4.createdBy => 'bypassAdmin'
        end
      end
          
      ##
      # Add fedora:lastModified and fedora:lastModifiedBy
      def modified!
        replace fcrepo4.lastModified => RDF::Literal::DateTime.new(Time.now.xmlschema), fcrepo4.lastModifiedBy => 'bypassAdmin'
      end

      ##
      # Add fedora:writable
      def writable!
        ensure_all(fcrepo4.writable => 'true')
      end

      ##
      # Add ldp:BasicContainer, fedora:Container, and fedora:Resource
      def container!
        env['HTTP_LINK'] ||= %{<http://www.w3.org/ns/ldp#Container>;rel="type"}
        ensure_all(RDF.type => ldp.BasicContainer, RDF.type => fcrepo4.Container, RDF.type => fcrepo4.Resource)
      end

      ##
      # Add fedora:RepositoryRoot to </>
      def repository_root!
        if env['PATH_INFO'] == '/'
          ensure_all(RDF.type => RDF::URI(fcrepo4.to_uri.to_s + "RepositoryRoot"))
        end
      end

      ##
      # COMPATIBILITY: fcrepo returns a 204 on successful PATCH; ActiveFedora fails on receiving a 200
      #  - 204 vs. 200 is already resolved in the Fedora API draft, would require an AF change
      def return_204_on_patch
        after_ldp(env) do |context|
          if context.env['REQUEST_METHOD'] == 'PATCH' and context.status == 200
            context.status = 204
            context.headers = {}
            context.body = ''
          end
        end
      end

      ##
      # COMPATIBILITY: fcrepo returns the URI of a newly created resource instead of the serialized resource
      #  - return on 201 is a Fedora API spec + derby question; or an AF bug, depending on the outcome
      def return_resource_uri_on_create
        after_ldp(env) do |context|
          if context.status == 201
            context.body = context.headers['Location'] || context.env['REQUEST_URI']
          end
        end
      end
      
      ##
      # Perform all updates
      def update!
        if ['POST','PUT','PATCH'].include?(env['REQUEST_METHOD']) or env['PATH_INFO'] == '/'
          if response.is_a?(RDF::LDP::RDFSource) and status.between?(200,299)
            container!
            repository_root! 
            writable!
            created!
            modified!
          end
          return_204_on_patch
          return_resource_uri_on_create
        end
        [status,headers,response]
      end
    end
    
    def initialize(app)
      @app = app
    end
    
    def call(env)
      (status, headers, response) = @app.call(env) unless @app.nil?
      Updater.new(env, status, headers, response).update!
    end
  end
end
