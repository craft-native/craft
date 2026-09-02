import { writable, derived } from 'svelte/store';

interface CraftAPI {
  getPlatform(): Promise<{ platform: string; version: string }>;
  getDeviceInfo(): Promise<{ platform: string; model: string; os_version: string }>;
  showToast(message: string, duration: 'short' | 'long'): Promise<void>;
  haptic(type: string): Promise<void>;
  requestPermission(permission: string): Promise<{ granted: boolean; message: string }>;
  on(event: string, callback: (...args: any[]) => void): void;
  off(event: string, callback: (...args: any[]) => void): void;
  emit(event: string, data?: any): void;
  invoke(method: string, params?: any): Promise<any>;
}

declare global {
  interface Window {
    craft?: CraftAPI;
  }
}

function createCraftStore() {
  const { subscribe, set } = writable<CraftAPI | null>(null);

  if (typeof window !== 'undefined') {
    if (window.craft) {
      set(window.craft);
    }
else {
      const checkCraft = setInterval(() => {
        if (window.craft) {
          set(window.craft);
          clearInterval(checkCraft);
        }
      }, 100);
    }
  }

  return {
    subscribe,
  };
}

export const craft = createCraftStore();
export const isReady = derived(craft, (_$craft) => _$craft !== null);
