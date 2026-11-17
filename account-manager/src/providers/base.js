// Base Provider Adapter
export class BaseProviderAdapter {
  constructor(name, type) {
    this.name = name;
    this.type = type;
  }

  // Returns supported login flow: 'device_code' | 'browser_redirect' | 'manual' | 'unsupported'
  getLoginFlow() {
    return 'unsupported';
  }

  // Initiate OAuth flow
  async initiateOAuth(options = {}) {
    throw new Error('Not implemented');
  }

  // Check login polling status
  async checkOAuthStatus(state) {
    throw new Error('Not implemented');
  }

  // Cancel login session
  async cancelOAuth(state) {
    throw new Error('Not implemented');
  }

  // Get models supported by this provider
  async getModels(cliProxyApiUrl) {
    return [];
  }

  // Perform quick chat/inference test
  async testConnection(cliProxyApiUrl, model) {
    throw new Error('Not implemented');
  }
}
