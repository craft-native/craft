import { useEffect, useState, useCallback, useRef, useMemo } from 'react';

// Type definitions for window.craft
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
 * Hook to access the Craft API
 * @returns The Craft API object or null if not available
 */
export function useCraft() {
  const [craft, setCraft] = useState<CraftAPI | null>(null);
  const [isReady, setIsReady] = useState(false);

  useEffect(() => {
    if (window.craft) {
      setCraft(window.craft);
      setIsReady(true);
    }
else {
      // Wait for craft to be ready
      const checkCraft = setInterval(() => {
        if (window.craft) {
          setCraft(window.craft);
          setIsReady(true);
          clearInterval(checkCraft);
        }
      }, 100);

      return () => clearInterval(checkCraft);
    }
  }, []);

  return { craft, isReady };
}

/**
 * Hook to get platform information
 * @returns Platform information and loading state
 */
export function usePlatform() {
  const { craft, isReady } = useCraft();
  const [platform, setPlatform] = useState<{ platform: string; version: string } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!isReady || !craft) return;

    craft.getPlatform()
      .then(setPlatform)
      .catch(setError)
      .finally(() => setLoading(false));
  }, [craft, isReady]);

  return { platform, loading, error };
}

/**
 * Hook to get device information
 * @returns Device information and loading state
 */
export function useDeviceInfo() {
  const { craft, isReady } = useCraft();
  const [deviceInfo, setDeviceInfo] = useState<{ platform: string; model: string; os_version: string } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!isReady || !craft) return;

    craft.getDeviceInfo()
      .then(setDeviceInfo)
      .catch(setError)
      .finally(() => setLoading(false));
  }, [craft, isReady]);

  return { deviceInfo, loading, error };
}

/**
 * Hook to show toast notifications
 * @returns Function to show toast
 */
export function useToast() {
  const { craft, isReady } = useCraft();

  const showToast = useCallback(
    async (message: string, duration: 'short' | 'long' = 'short') => {
      if (!isReady || !craft) {
        console.warn('Craft not ready');
        return;
      }
      await craft.showToast(message, duration);
    },
    [craft, isReady]
  );

  return { showToast };
}

/**
 * Hook to trigger haptic feedback
 * @returns Function to trigger haptic
 */
export function useHaptic() {
  const { craft, isReady } = useCraft();

  const haptic = useCallback(
    async (type: string = 'selection') => {
      if (!isReady || !craft) {
        console.warn('Craft not ready');
        return;
      }
      try {
        await craft.haptic(type);
      }
      catch (error) {
        // Feedback: an app built with haptics off plays nothing, the same as
        // Craft not being ready. Any other failure still reaches the caller.
        if ((error as { code?: string } | null)?.code !== 'CAPABILITY_DISABLED') throw error;
      }
    },
    [craft, isReady]
  );

  return { haptic };
}

/**
 * Hook to request permissions
 * @returns Function to request permission and permission state
 */
export function usePermission(permission: string) {
  const { craft, isReady } = useCraft();
  const [granted, setGranted] = useState<boolean | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const request = useCallback(async () => {
    if (!isReady || !craft) {
      console.warn('Craft not ready');
      return;
    }

    setLoading(true);
    try {
      const result = await craft.requestPermission(permission);
      setGranted(result.granted);
    }
catch (err) {
      setError(err as Error);
    }
finally {
      setLoading(false);
    }
  }, [craft, isReady, permission]);

  return { granted, request, loading, error };
}

/**
 * Hook to listen to Craft events
 * @param event Event name to listen to
 * @param callback Callback function
 */
export function useCraftEvent(event: string, callback: (...args: any[]) => void) {
  const { craft, isReady } = useCraft();
  const callbackRef = useRef(callback);

  useEffect(() => {
    callbackRef.current = callback;
  }, [callback]);

  useEffect(() => {
    if (!isReady || !craft) return;

    const handler = (...args: any[]) => callbackRef.current(...args);
    craft.on(event, handler);

    return () => {
      craft.off(event, handler);
    };
  }, [craft, isReady, event]);
}

/**
 * Hook to invoke Craft methods
 * @returns Function to invoke methods
 */
export function useCraftInvoke() {
  const { craft, isReady } = useCraft();

  const invoke = useCallback(
    async (method: string, params?: any) => {
      if (!isReady || !craft) {
        throw new Error('Craft not ready');
      }
      return await craft.invoke(method, params);
    },
    [craft, isReady]
  );

  return { invoke, isReady };
}

/**
 * Hook to check if running on mobile
 * @returns Whether running on mobile platform
 */
export function useIsMobile() {
  const { platform } = usePlatform();

  return useMemo(() => {
    if (!platform) return false;
    return platform.platform === 'ios' || platform.platform === 'android';
  }, [platform]);
}

/**
 * Hook to check if running on desktop
 * @returns Whether running on desktop platform
 */
export function useIsDesktop() {
  const { platform } = usePlatform();

  return useMemo(() => {
    if (!platform) return false;
    return platform.platform === 'macos' || platform.platform === 'windows' || platform.platform === 'linux';
  }, [platform]);
}

// Re-export everything
export * from './hooks/useWindow';
export * from './hooks/useTray';
export * from './hooks/useNotification';
export * from './hooks/useFileSystem';
export * from './hooks/useDatabase';
export * from './hooks/useHttp';
