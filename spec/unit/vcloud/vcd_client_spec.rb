require "spec_helper"

module VCloudCloud
  class VCloudClient
    attr_accessor :cache, :org_link
  end

  describe VCloudClient do
    logger = Bosh::Clouds::Config.logger
    let(:settings) { Test.vcd_settings }
    let(:client) { described_class.new(settings, logger)}

    describe '.initialize' do
      it 'read control settings from configuration file' do
        verify_control_settings :@wait_max => 400, :@wait_delay => 10, :@retry_max => 5, :@retry_delay => 500, :@cookie_timeout => 1200
      end

      it 'use default control settings if not specified in configuration file' do
        settings['entities']['control'] = nil
        verify_control_settings :@wait_max => VCloudClient::WAIT_MAX, :@wait_delay => VCloudClient::WAIT_DELAY, \
          :@retry_max => VCloudClient::RETRY_MAX, :@retry_delay => VCloudClient::RETRY_DELAY, :@cookie_timeout => VCloudClient::COOKIE_TIMEOUT
      end

      private
      def verify_control_settings(control_settings)
        control_settings.each do |instance_variable_name, target_numeric_value|
          instance_variable = client.instance_variable_get(instance_variable_name)
          instance_variable.should eql target_numeric_value
        end
      end
    end

    describe ".invoke" do

      it "setup restclient in absence of proxy" do
        restclient = double("rest client")

        client.should_receive(:proxy_from_env).and_return nil
        RestClient::Request.should_receive(:new).and_return restclient
        restclient.should_not_receive(:proxy)

        client.send(:setup_restclient, nil)
      end

      it "setup restclient in presence of proxy" do
        restclient = double("rest client")

        client.should_receive(:proxy_from_env).and_return 'http://myproxy:3128'
        RestClient::Request.should_receive(:new).and_return restclient
        restclient.should_receive(:proxy).with('http://myproxy:3128')

        client.send(:setup_restclient, nil)
      end

      it "extract https_proxy and http_proxy from env as a proxy uri" do
        client.proxy_from_env.should be_nil
      end

      it "fetch auth header" do
        version_response = double('version_response')
        url_node = double('login url node')
        url_node.stub_chain('login_url.content').and_return '/api/sessions'
        client.should_receive(:wrap_response).with(version_response).and_return url_node

        login_response = double('login_response')
        cookies = "cookies string"
        auth_token = {:x_vcloud_authorization => auth_token }
        login_response.should_receive(:headers).and_return auth_token
        login_response.should_receive(:cookies).and_return cookies
        base_url = URI.parse(settings['url'])

        session = double("session")
        session.should_receive(:entity_resolver)
        session.should_receive(:org_link)
        client.should_receive(:wrap_response).with(login_response).and_return session

        info_response = double("info response")
        info_response.should_receive(:code).and_return 204

        restclient_helper = double("rest client helper")
        restclient = double("rest client")
        VCloudCloud::RestClientHelper.should_receive(:new).at_least(1).times.and_return(restclient_helper)

        # version
        restclient_helper.should_receive(:setup_restclient) do |arg|
          arg[:url].should == base_url.merge('/api/versions').to_s
          arg[:cookies].should be_nil
        end.and_return restclient
        restclient.should_receive(:execute).and_return version_response

        # login
        restclient_helper.should_receive(:setup_restclient) do |arg|
          arg[:url].should == base_url.merge("/api/sessions").to_s
          arg[:cookies].should be_nil
        end.and_return restclient
        restclient.should_receive(:execute).and_return login_response

        # /info
        restclient_helper.should_receive(:setup_restclient) do |arg|
          arg[:url].should == base_url.merge("/info").to_s
          arg[:cookies].should == cookies
        end.and_return restclient
        restclient.should_receive(:execute).and_return info_response

        client.invoke :get, "/info"
      end
    end

    describe "trivia methods" do
      it "reads properties from settings" do
        [
          [:org_name, :organization],
          [:vdc_name, :virtual_datacenter],
          [:vapp_catalog_name, :vapp_catalog],
          [:media_catalog_name, :media_catalog],
        ].each do |props|
          method, prop = props
          client.send(method).should == settings['entities'][prop.to_s]
        end
      end
    end

    describe ".org" do
      it "reads cache" do
        client.cache.should_receive(:get).with(:org)

        client.org
      end

      it "fetch org info when cache is missing" do
        client.cache.clear
        org_link = "org_link"
        client.org_link = org_link
        client.should_receive(:session)
        client.should_receive(:resolve_link).with(org_link)

        client.org
      end
    end

    describe ".vdc" do
      it "reads cache" do
        client.cache.should_receive(:get).with(:vdc)

        client.vdc
      end

      it "fetch vdc info when cache is missing" do
        client.cache.clear
        vdc_link = "vdc_link"
        org = double("org")
        org.should_receive(:vdc_link).with(client.vdc_name).
          and_return(vdc_link)
        client.should_receive(:org).and_return(org)
        client.should_receive(:resolve_link).with(vdc_link)

        client.vdc
      end

      it "raise error when vdc is not found" do
        client.cache.clear
        vdc_link = "vdc_link"
        org = double("org")
        org.should_receive(:vdc_link).with(client.vdc_name).
          and_return(nil)
        client.should_receive(:org).and_return(org)

        expect{client.vdc}.to raise_error(
          ObjectNotFoundError, /#{client.vdc_name}/)
      end
    end

    describe ".catalog_item" do
      it "return the first matched item in catalog" do
        catalog_type = :media
        catalog_name = "demo"
        type = VCloudSdk::Xml::MEDIA_TYPE[:MEDIA]
        items = [ "i1", "i2" ]
        object1 = double("o1")
        object1.should_receive(:entity).and_return({'type' => type})
        client.should_receive(:resolve_link).and_return object1
        catalog = double("catalog")
        catalog.should_receive(:catalog_items).with(catalog_name).
          and_return(items)
        client.should_receive(:catalog).with(catalog_type).
          and_return(catalog)

        client.catalog_item(catalog_type, catalog_name,type)
      end
    end

    describe ".reload" do
      it "reload object from link" do
        object = double("o1")
        link = "obj_link"
        object.should_receive(:href).and_return(link)
        client.should_receive(:invoke).and_return object

        client.reload(object).should == object
      end
    end

    describe ".wait_entity" do
      it "wait for running tasks" do
        entity = double("entity")
        client.stub(:reload) do |args|
          args
        end
        task = double("task")
        task.should_receive(:urn).and_return "urn"
        task.should_receive(:operation).and_return "update"
        task.stub(:status).and_return VCloudSdk::Xml::TASK_STATUS[:SUCCESS]
        entity.stub(:running_tasks) {[task]}
        entity.stub(:tasks) {[task]}

        client.wait_entity(entity)
      end

      it "raise error when running task failed" do
        entity = double("entity")
        client.stub(:reload) do |args|
          args
        end
        task = double("task")
        task.stub(:urn).and_return "urn"
        task.stub(:operation).and_return "update"
        task.stub(:status).and_return VCloudSdk::Xml::TASK_STATUS[:ERROR]
        entity.stub(:running_tasks) {[task]}
        entity.stub(:tasks) {[task]}

        expect{client.wait_entity(entity)}.to raise_error /unsuccessful/
      end

      it "raise error when completed task failed" do
        entity = double("entity")
        client.stub(:reload) do |args|
          args
        end
        task = double("task")
        task.stub(:status).and_return VCloudSdk::Xml::TASK_STATUS[:ERROR]
        entity.stub(:running_tasks) {[]}
        entity.stub(:tasks) {[task]}

        expect{client.wait_entity(entity)}.to raise_error /tasks failed/
      end
    end
  end

  describe RestClientHelper do
    context 'proxy_from_env' do
      it 'prefers env $https_proxy over $http_proxy' do
        stub_const('ENV', { 'https_proxy' => 'http://httpsproxy:3128','http_proxy' => 'http://httpproxy:3128'})
        subject.proxy_from_env.should eq('http://httpsproxy:3128')
      end
      it 'uses env $https_proxy or $HTTP_PROXY if defined' do
        stub_const('ENV', { 'https_proxy' => 'http://httpsproxy:3128'})
        subject.proxy_from_env.should eq('http://httpsproxy:3128')
        stub_const('ENV', { 'HTTPS_PROXY' => 'http://httpsproxy:3128'})
        subject.proxy_from_env.should eq('http://httpsproxy:3128')
      end
      it 'uses env $http_proxy if defined' do
        stub_const('ENV', { 'http_proxy' => 'http://httpproxy:3128'})
        subject.proxy_from_env.should eq('http://httpproxy:3128')
        stub_const('ENV', { 'HTTP_PROXY' => 'http://httpproxy:3128'})
        subject.proxy_from_env.should eq('http://httpproxy:3128')
      end
      it 'returns nil when no proxy defined in envs' do
        stub_const('ENV', { })
        subject.proxy_from_env.should nil
      end
    end

    context 'setup_restclient' do
      it 'instanciates a plain RestClient by default' do
        subject.should_receive(:proxy_from_env).and_return(nil)
        restclient = double("rest client")
        RestClient::Request.should_receive(:new).and_return restclient
        restclient.should_not_receive(:proxy)

        subject.setup_restclient({})
      end

      it 'instanciates a RestClient assigning proxy when defined' do
        subject.should_receive(:proxy_from_env).and_return('http://httpsproxy:3128')
        restclient = double("rest client")
        RestClient::Request.should_receive(:new).and_return restclient
        restclient.should_receive(:proxy).with('http://httpsproxy:3128')

        subject.setup_restclient({})
      end

    end
  end
end
