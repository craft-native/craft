import { useState, useCallback } from 'react';
import { useCraft } from '../index';

interface WindowOptions {
  title?: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  resizable?: boolean;
  fullscreen?: boolean;
  transparent?: boolean;
  alwaysOnTop?: boolean;
}

/**
 * Hook to manage application window
 */
export function useWindow() {
  const { craft, isReady } = useCraft();
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [isMaximized, setIsMaximized] = useState(false);
  const [isMinimized, setIsMinimized] = useState(false);

  const setTitle = useCallback(
    async (title: string) => {
      if (!isReady || !craft) return;
      await craft.invoke('window.setTitle', { title });
    },
    [craft, isReady]
  );

  const setSize = useCallback(
    async (width: number, height: number) => {
      if (!isReady || !craft) return;
      await craft.invoke('window.setSize', { width, height });
    },
    [craft, isReady]
  );

  const setPosition = useCallback(
    async (x: number, y: number) => {
      if (!isReady || !craft) return;
      await craft.invoke('window.setPosition', { x, y });
    },
    [craft, isReady]
  );

  const maximize = useCallback(async () => {
    if (!isReady || !craft) return;
    await craft.invoke('window.maximize');
    setIsMaximized(true);
  }, [craft, isReady]);

  const minimize = useCallback(async () => {
    if (!isReady || !craft) return;
    await craft.invoke('window.minimize');
    setIsMinimized(true);
  }, [craft, isReady]);

  const restore = useCallback(async () => {
    if (!isReady || !craft) return;
    await craft.invoke('window.restore');
    setIsMaximized(false);
    setIsMinimized(false);
  }, [craft, isReady]);

  const toggleFullscreen = useCallback(async () => {
    if (!isReady || !craft) return;
    await craft.invoke('window.toggleFullscreen');
    setIsFullscreen(!isFullscreen);
  }, [craft, isReady, isFullscreen]);

  const close = useCallback(async () => {
    if (!isReady || !craft) return;
    await craft.invoke('window.close');
  }, [craft, isReady]);

  const center = useCallback(async () => {
    if (!isReady || !craft) return;
    await craft.invoke('window.center');
  }, [craft, isReady]);

  const setAlwaysOnTop = useCallback(
    async (alwaysOnTop: boolean) => {
      if (!isReady || !craft) return;
      await craft.invoke('window.setAlwaysOnTop', { alwaysOnTop });
    },
    [craft, isReady]
  );

  return {
    isFullscreen,
    isMaximized,
    isMinimized,
    setTitle,
    setSize,
    setPosition,
    maximize,
    minimize,
    restore,
    toggleFullscreen,
    close,
    center,
    setAlwaysOnTop,
  };
}
