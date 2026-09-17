import { get } from 'svelte/store';
import { craft } from '../stores/craft';

export function haptic(node: HTMLElement, type: string = 'selection') {
  const handleClick = async () => {
    const _$craft = get(craft);
    if (!_$craft) return;
    try {
      await _$craft.haptic(type);
    }
    catch (error) {
      // Feedback: an app built with haptics off plays nothing on click, rather
      // than an unhandled rejection. Any other failure still surfaces.
      if ((error as { code?: string } | null)?.code !== 'CAPABILITY_DISABLED') throw error;
    }
  };

  node.addEventListener('click', handleClick);

  return {
    destroy() {
      node.removeEventListener('click', handleClick);
    },
  };
}
