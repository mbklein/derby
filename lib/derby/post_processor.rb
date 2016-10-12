module Derby
  module Events
    def after_ldp(env, &block)
      (env["derby.post"] ||= []) << block
    end
  end
  
  class PostProcessor
    def initialize(app)
      @app = app
    end
    
    def call(env)
      (s,h,b) = @app.call(env) unless @app.nil?
      context = OpenStruct.new(env: env, status: s, headers: h, body: b)
      Array(env['derby.post']).each do |proc|
        proc.call(context) if proc.respond_to?(:call)
      end
      [context.status, context.headers, Array(context.body)]
    end
  end
end
