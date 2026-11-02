require 'spec_helper'

RSpec.describe 'CF_EXECUTION_BACKEND validation' do
  let(:user) { create(:user) }
  let(:user_header) { headers_for(user) }
  let(:space) { create(:space) }
  let(:stack) { create(:stack) }
  let(:detail) { 'CF_EXECUTION_BACKEND must be one of oci-runc, oci-gvisor, vm-qemu, or vm-firecracker' }
  let(:build_client) { instance_double(HTTPClient, post: nil) }

  before do
    space.organization.add_user(user)
    space.add_developer(user)
    TestConfig.override(kubernetes: {})
    allow_any_instance_of(Diego::Client).to receive(:build_client).and_return(build_client)
  end

  describe 'POST /v3/apps' do
    it 'returns a 422 for an unknown backend' do
      post '/v3/apps', {
        name: 'my_app',
        environment_variables: { CF_EXECUTION_BACKEND: 'vm-kvm' },
        lifecycle: { type: 'buildpack', data: { stack: stack.name, buildpacks: [] } },
        relationships: { space: { data: { guid: space.guid } } }
      }.to_json, user_header

      expect(last_response).to have_status_code(422)
      expect(parsed_response['errors'][0]['detail']).to include(detail)
      expect(VCAP::CloudController::AppModel.where(name: 'my_app')).to be_empty
    end
  end

  describe 'POST /v3/spaces/:guid/actions/apply_manifest' do
    let(:app_model) { create(:app_model, name: 'manifest-app', space: space) }

    it 'returns a 422 for an unknown backend' do
      manifest = { 'applications' => [{ 'name' => app_model.name, 'env' => { 'CF_EXECUTION_BACKEND' => 'vm-kvm' } }] }.to_yaml

      post "/v3/spaces/#{space.guid}/actions/apply_manifest", manifest, yml_headers(user_header)

      expect(last_response).to have_status_code(422)
      expect(parsed_response['errors'][0]['detail']).to include(detail)
      expect(app_model.reload.environment_variables).to be_nil.or be_empty
    end
  end

  describe 'PATCH /v3/environment_variable_groups/:name' do
    let(:group) { VCAP::CloudController::EnvironmentVariableGroup.running }

    it 'returns a 422 for an unknown backend' do
      patch '/v3/environment_variable_groups/running', { var: { CF_EXECUTION_BACKEND: 'vm-kvm' } }.to_json, admin_headers

      expect(last_response).to have_status_code(422)
      expect(parsed_response['errors'][0]['detail']).to include(detail)
      expect(group.reload.environment_json).to eq({})
    end

    it 'returns a 422 for a false backend value' do
      patch '/v3/environment_variable_groups/running', { var: { 'CF_EXECUTION_BACKEND' => false } }.to_json, admin_headers

      expect(last_response).to have_status_code(422)
    end

    context 'when the group already holds an unknown backend' do
      before do
        group.environment_json = { 'CF_EXECUTION_BACKEND' => 'legacy', 'KEEP' => 'me' }
        group.save(validate: false)
      end

      it 'still patches an unrelated variable' do
        patch '/v3/environment_variable_groups/running', { var: { OTHER: 'value' } }.to_json, admin_headers

        expect(last_response).to have_status_code(200)
        expect(group.reload.environment_json).to include('CF_EXECUTION_BACKEND' => 'legacy', 'OTHER' => 'value')
      end

      it 'returns a 422 when the patch changes the unknown backend to another unknown one' do
        patch '/v3/environment_variable_groups/running', { var: { CF_EXECUTION_BACKEND: 'other-legacy' } }.to_json, admin_headers

        expect(last_response).to have_status_code(422)
      end

      it 'accepts a patch that fixes the backend' do
        patch '/v3/environment_variable_groups/running', { var: { CF_EXECUTION_BACKEND: 'vm-qemu' } }.to_json, admin_headers

        expect(last_response).to have_status_code(200)
      end
    end
  end

  describe 'POST /v2/apps' do
    it 'rejects an unknown backend' do
      post '/v2/apps', Oj.dump({
                                 name: 'v2-app',
                                 space_guid: space.guid,
                                 stack_guid: stack.guid,
                                 environment_json: { 'CF_EXECUTION_BACKEND' => 'vm-kvm' }
                               }), user_header

      expect(last_response.status).to be_between(400, 422)
      expect(last_response.body).to include('CF_EXECUTION_BACKEND must be one of')
      expect(VCAP::CloudController::AppModel.where(name: 'v2-app')).to be_empty
    end
  end

  describe 'PATCH /v3/apps/:guid/environment_variables' do
    let(:app_model) { create(:app_model, name: 'legacy-app', space: space, desired_state: 'STOPPED') }

    before do
      app_model.environment_variables = { 'CF_EXECUTION_BACKEND' => 'legacy', 'KEEP' => 'me' }
      app_model.save(validate: false)
    end

    it 'returns a 422 for a false backend value under a string key' do
      patch "/v3/apps/#{app_model.guid}/environment_variables", { var: { 'CF_EXECUTION_BACKEND' => false } }.to_json, user_header

      expect(last_response).to have_status_code(422)
    end

    context 'when the app was saved with an unknown backend before the check existed' do
      it 'still patches an unrelated variable' do
        patch "/v3/apps/#{app_model.guid}/environment_variables", { var: { OTHER: 'value' } }.to_json, user_header

        expect(last_response).to have_status_code(200)
        expect(app_model.reload.environment_variables).to include('CF_EXECUTION_BACKEND' => 'legacy', 'OTHER' => 'value')
      end

      it 'returns a 422 rather than a 500 when the unknown backend changes to another unknown one' do
        patch "/v3/apps/#{app_model.guid}/environment_variables", { var: { CF_EXECUTION_BACKEND: 'other-legacy' } }.to_json, user_header

        expect(last_response).to have_status_code(422)
      end

      it 'can be stopped, started, and scaled' do
        droplet = create(:droplet_model, app: app_model, state: VCAP::CloudController::DropletModel::STAGED_STATE)
        app_model.update(droplet: droplet)
        process = create(:process_model, :process, app: app_model, type: 'web', instances: 1, command: 'rackup')

        post "/v3/apps/#{app_model.guid}/actions/start", nil, user_header
        expect(last_response).to have_status_code(200)

        post "/v3/apps/#{app_model.guid}/actions/stop", nil, user_header
        expect(last_response).to have_status_code(200)

        post "/v3/processes/#{process.guid}/actions/scale", { instances: 3 }.to_json, user_header
        expect(last_response).to have_status_code(202)
        expect(process.reload.instances).to eq(3)
      end
    end
  end
end
