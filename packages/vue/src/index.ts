import { ref, onMounted, onUnmounted, computed, watch } from 'vue';

// Type definitions
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

/**
 * Composable to access the Craft API
 */
export function useCraft() {
  const craft = ref<CraftAPI | null>(null);
  const isReady = ref(false);

  onMounted(() => {
    if (window.craft) {
      craft.value = window.craft;
      isReady.value = true;
    }
else {
      // Wait for craft to be ready
      const checkCraft = setInterval(() => {
        if (window.craft) {
          craft.value = window.craft;
          isReady.value = true;
          clearInterval(checkCraft);
        }
      }, 100);

      onUnmounted(() => clearInterval(checkCraft));
    }
  });

  return { craft, isReady };
}

/**
 * Composable to get platform information
 */
export function usePlatform() {
  const { craft, isReady } = useCraft();
  const platform = ref<{ platform: string; version: string } | null>(null);
  const loading = ref(true);
  const error = ref<Error | null>(null);

  watch(isReady, async (ready) => {
    if (ready && craft.value) {
      try {
        platform.value = await craft.value.getPlatform();
      }
catch (err) {
        error.value = err as Error;
      }
finally {
        loading.value = false;
      }
    }
  }, { immediate: true });

  return { platform, loading, error };
}

/**
 * Composable to get device information
 */
export function useDeviceInfo() {
  const { craft, isReady } = useCraft();
  const deviceInfo = ref<{ platform: string; model: string; os_version: string } | null>(null);
  const loading = ref(true);
  const error = ref<Error | null>(null);

  watch(isReady, async (ready) => {
    if (ready && craft.value) {
      try {
        deviceInfo.value = await craft.value.getDeviceInfo();
      }
catch (err) {
        error.value = err as Error;
      }
finally {
        loading.value = false;
      }
    }
  }, { immediate: true });

  return { deviceInfo, loading, error };
}

/**
 * Composable to show toast notifications
 */
export function useToast() {
  const { craft, isReady } = useCraft();

  const showToast = async (message: string, duration: 'short' | 'long' = 'short') => {
    if (!isReady.value || !craft.value) {
      console.warn('Craft not ready');
      return;
    }
    await craft.value.showToast(message, duration);
  };

  return { showToast };
}

/**
 * Composable to trigger haptic feedback
 */
export function useHaptic() {
  const { craft, isReady } = useCraft();

  const haptic = async (type: string = 'selection') => {
    if (!isReady.value || !craft.value) {
      console.warn('Craft not ready');
      return;
    }
    try {
      await craft.value.haptic(type);
    }
    catch (error) {
      // Feedback: an app built with haptics off plays nothing, the same as
      // Craft not being ready. Any other failure still reaches the caller.
      if ((error as { code?: string } | null)?.code !== 'CAPABILITY_DISABLED') throw error;
    }
  };

  return { haptic };
}

/**
 * Composable to request permissions
 */
export function usePermission(permission: string) {
  const { craft, isReady } = useCraft();
  const granted = ref<boolean | null>(null);
  const loading = ref(false);
  const error = ref<Error | null>(null);

  const request = async () => {
    if (!isReady.value || !craft.value) {
      console.warn('Craft not ready');
      return;
    }

    loading.value = true;
    try {
      const result = await craft.value.requestPermission(permission);
      granted.value = result.granted;
    }
catch (err) {
      error.value = err as Error;
    }
finally {
      loading.value = false;
    }
  };

  return { granted, request, loading, error };
}

/**
 * Composable to listen to Craft events
 */
export function useCraftEvent(event: string, callback: (...args: any[]) => void) {
  const { craft, isReady } = useCraft();

  const unsubscribe = () => {
    if (craft.value) {
      craft.value.off(event, callback);
    }
  };

  watch(isReady, (ready) => {
    if (ready && craft.value) {
      craft.value.on(event, callback);
    }
  }, { immediate: true });

  onUnmounted(unsubscribe);

  return { unsubscribe };
}

/**
 * Composable to invoke Craft methods
 */
export function useCraftInvoke() {
  const { craft, isReady } = useCraft();

  const invoke = async (method: string, params?: any) => {
    if (!isReady.value || !craft.value) {
      throw new Error('Craft not ready');
    }
    return await craft.value.invoke(method, params);
  };

  return { invoke, isReady };
}

/**
 * Composable to check if running on mobile
 */
export function useIsMobile() {
  const { platform } = usePlatform();

  const isMobile = computed(() => {
    if (!platform.value) return false;
    return platform.value.platform === 'ios' || platform.value.platform === 'android';
  });

  return isMobile;
}

/**
 * Composable to check if running on desktop
 */
export function useIsDesktop() {
  const { platform } = usePlatform();

  const isDesktop = computed(() => {
    if (!platform.value) return false;
    return ['macos', 'windows', 'linux'].includes(platform.value.platform);
  });

  return isDesktop;
}

// Re-export composables
export * from './composables/useWindow';
export * from './composables/useTray';
export * from './composables/useNotification';
export * from './composables/useFileSystem';
export * from './composables/useDatabase';
export * from './composables/useHttp';
