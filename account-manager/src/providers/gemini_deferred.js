import { BaseProviderAdapter } from './base.js';

export class GeminiDeferredAdapter extends BaseProviderAdapter {
  constructor() {
    super('Gemini (Antigravity)', 'gemini');
  }

  getLoginFlow() {
    return 'unsupported';
  }

  async initiateOAuth() {
    return {
      success: false,
      error: 'Gemini/Antigravity provider integration is intentionally deferred per project safety guidelines.'
    };
  }

  async checkOAuthStatus() {
    return {
      status: 'error',
      error: 'Gemini provider is deferred.'
    };
  }

  async cancelOAuth() {
    return false;
  }

  async getModels() {
    return [];
  }

  async testConnection() {
    return {
      success: false,
      statusCode: 400,
      error: 'Gemini provider testing is disabled.'
    };
  }
}
