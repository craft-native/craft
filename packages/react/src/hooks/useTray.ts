import { useCallback, useState } from 'react';
import { useCraft } from '../index';

interface TrayMenuItem {
  label: string;
  id: string;
  enabled?: boolean;
  checked?: boolean;
  type?: 'normal' | 'separator' | 'checkbox';
  submenu?: TrayMenuItem[];
}

/**
 * Hook to manage system tray icon
 */
export function useTray() {
  const { craft, isReady } = useCraft();
  const [isVisible, setIsVisible] = useState(false);

  const create = useCallback(
    async (icon?: string, tooltip?: string) => {
      if (!isReady || !craft) return;
      await craft.invoke('tray.create', { icon, tooltip });
      setIsVisible(true);
    },
    [craft, isReady]
  );

  const destroy = useCallback(async () => {
    if (!isReady || !craft) return;
    await craft.invoke('tray.destroy');
    setIsVisible(false);
  }, [craft, isReady]);

  const setIcon = useCallback(
    async (icon: string) => {
      if (!isReady || !craft) return;
      await craft.invoke('tray.setIcon', { icon });
    },
    [craft, isReady]
  );

  const setTooltip = useCallback(
    async (tooltip: string) => {
      if (!isReady || !craft) return;
      await craft.invoke('tray.setTooltip', { tooltip });
    },
    [craft, isReady]
  );

  const setMenu = useCallback(
    async (menu: TrayMenuItem[]) => {
      if (!isReady || !craft) return;
      await craft.invoke('tray.setMenu', { menu });
    },
    [craft, isReady]
  );

  const setTitle = useCallback(
    async (title: string) => {
      if (!isReady || !craft) return;
      await craft.invoke('tray.setTitle', { title });
    },
    [craft, isReady]
  );

  return {
    isVisible,
    create,
    destroy,
    setIcon,
    setTooltip,
    setMenu,
    setTitle,
  };
}
