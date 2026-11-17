import { CodexAdapter } from './codex.js';
import { XAIAdapter } from './xai.js';
import { GeminiDeferredAdapter } from './gemini_deferred.js';

export function createProviderRegistry(config) {
  const providers = new Map();

  const codex = new CodexAdapter({
    cliProxyApiUrl: config.cliProxyApiUrl,
    managementKey: config.cliProxyApiManagementKey,
    authDir: config.authDir
  });

  const xai = new XAIAdapter({
    cliProxyApiUrl: config.cliProxyApiUrl,
    managementKey: config.cliProxyApiManagementKey,
    authDir: config.authDir
  });

  const gemini = new GeminiDeferredAdapter();

  providers.set('codex', codex);
  providers.set('xai', xai);
  providers.set('gemini', gemini);

  return {
    get(type) {
      return providers.get(type.toLowerCase()) || null;
    },
    list() {
      return Array.from(providers.values()).map(p => ({
        name: p.name,
        type: p.type,
        flow: p.getLoginFlow(),
        supported: p.getLoginFlow() !== 'unsupported'
      }));
    }
  };
}
