/**
 * Craft Sidebar HTML Templates
 * Ready-to-use HTML templates for each sidebar style
 *
 * These can be rendered directly in Craft WebView or used as
 * reference for building your own components.
 *
 * @module @craft-native/styles/sidebar-templates
 */

import { tahoeStyles, arcStyles, orbstackStyles } from './sidebars.js'

// ============================================================================
// Types
// ============================================================================

export interface SidebarItemData {
  id: string
  label: string
  icon?: string
  badge?: string | number
  selected?: boolean
  children?: SidebarItemData[]
  expanded?: boolean
  status?: 'running' | 'stopped' | 'none'
  color?: string
}

export interface SidebarSectionData {
  id: string
  title?: string
  items: SidebarItemData[]
  collapsible?: boolean
  collapsed?: boolean
}

export interface SidebarData {
  sections?: SidebarSectionData[]
  items?: SidebarItemData[]
  header?: {
    title?: string
    subtitle?: string
    avatar?: string
  }
  footer?: {
    items?: SidebarItemData[]
  }
  searchPlaceholder?: string
  showSearch?: boolean
}

// ============================================================================
// Icon SVGs (SF Symbol-like)
// ============================================================================

const icons = {
  home: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6'/></svg>`,
  folder: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z'/></svg>`,
  document: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z'/></svg>`,
  star: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z'/></svg>`,
  download: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4'/></svg>`,
  cloud: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M3 15a4 4 0 004 4h9a5 5 0 10-.1-9.999 5.002 5.002 0 10-9.78 2.096A4.001 4.001 0 003 15z'/></svg>`,
  settings: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z'/><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M15 12a3 3 0 11-6 0 3 3 0 016 0z'/></svg>`,
  plus: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M12 4v16m8-8H4'/></svg>`,
  search: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z'/></svg>`,
  chevronRight: `<svg class='h-3 w-3' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M9 5l7 7-7 7'/></svg>`,
  chevronDown: `<svg class='h-3 w-3' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M19 9l-7 7-7-7'/></svg>`,
  x: `<svg class='h-3 w-3' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M6 18L18 6M6 6l12 12'/></svg>`,
  menu: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M4 6h16M4 12h16M4 18h16'/></svg>`,
  container: `<svg class='h-4 w-4' fill='none' stroke='currentColor' viewBox='0 0 24 24'><path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4'/></svg>`,
  linux: `<svg class='h-4 w-4' fill='currentColor' viewBox='0 0 24 24'><path d='M12.504 0c-.155 0-.311.001-.465.003-.653.014-1.304.07-1.952.17-1.328.205-2.607.596-3.796 1.157-1.189.56-2.28 1.293-3.234 2.174-.954.88-1.757 1.9-2.384 3.022-.627 1.122-1.07 2.342-1.313 3.608-.244 1.266-.286 2.575-.126 3.855.16 1.28.519 2.517 1.066 3.666.547 1.149 1.274 2.197 2.152 3.105.877.908 1.9 1.666 3.025 2.249 1.126.583 2.349.984 3.609 1.192 1.261.208 2.555.218 3.82.029 1.265-.189 2.497-.576 3.642-1.148 1.145-.572 2.187-1.32 3.086-2.212.898-.892 1.643-1.922 2.212-3.045.568-1.123.952-2.332 1.138-3.577.186-1.245.176-2.518-.03-3.766-.206-1.248-.607-2.462-1.191-3.588-.583-1.125-1.343-2.15-2.25-3.029-.907-.879-1.957-1.607-3.1-2.156-1.142-.548-2.377-.913-3.643-1.078-.653-.085-1.31-.125-1.966-.125z'/></svg>`,
}

function getIcon(name: string): string {
  return icons[name as keyof typeof icons] || icons.document
}

// ============================================================================
// Tahoe Template (macOS Tahoe source list)
// ============================================================================

// eslint-disable-next-line pickier/no-unused-vars
export function renderTahoeSidebar(data: SidebarData): string {
  const s = tahoeStyles

  const renderItem = (item: SidebarItemData, depth = 0): string => {
    const isSelected = item.selected
    const itemClass = isSelected ? s.itemSelected : s.item
    const iconClass = isSelected ? s.itemIconSelected : s.itemIcon
    const badgeClass = isSelected ? s.itemBadgeSelected : s.itemBadge
    const hasChildren = (item.children?.length ?? 0) > 0
    // macOS reserves the disclosure gutter on every row so icons align;
    // the chevron only appears on expandable rows, pointing down when open.
    const chevron = hasChildren
      ? `<span class='${s.disclosureChevron}${item.expanded ? ' rotate-90' : ''}'>${icons.chevronRight}</span>`
      : ''
    // Icon tint accepts any CSS color; defaults to the class's system blue.
    const tint = item.color ? ` style='color: ${item.color}'` : ''

    let html = `
      <div class='${itemClass}' data-id='${item.id}'${depth > 0 ? ` style='padding-left: ${4 + depth * 16}px'` : ''}>
        <span class='${s.disclosure}'>${chevron}</span>
        <span class='${s.itemIconSlot}'><span class='${iconClass}'${tint}>${getIcon(item.icon || 'document')}</span></span>
        <span class='${s.itemLabel}'>${item.label}</span>
        ${item.badge ? `<span class='${badgeClass}'>${item.badge}</span>` : ''}
      </div>
    `

    if (item.children && item.expanded) {
      item.children.forEach(child => {
        html += renderItem(child, depth + 1)
      })
    }

    return html
  }

  // eslint-disable-next-line pickier/no-unused-vars
  const renderSection = (section: SidebarSectionData): string => {
    return `
      <div class='${s.section}'>
        ${section.title ? `
          <div class="${section.collapsible ? s.sectionHeaderCollapsible : s.sectionHeader}" data-section="${section.id}">
            <span class='truncate'>${section.title}</span>
            ${section.collapsible ? `<span class='${s.collapseChevron}${section.collapsed ? ' -rotate-90' : ''}'>${icons.chevronDown}</span>` : ''}
          </div>
        ` : ''}
        ${!section.collapsed ? section.items.map(item => renderItem(item)).join('') : ''}
      </div>
    `
  }

  return `
    <div class='${s.sidebar}'>
      ${data.header ? `
        <div class='${s.header}'>
          ${data.header.avatar ? `
            <div class="${s.headerAvatar}">${data.header.avatar}</div>
          ` : ''}
          <div>
            ${data.header.title ? `<div class="${s.headerTitle}">${data.header.title}</div>` : ''}
            ${data.header.subtitle ? `<div class="${s.headerSubtitle}">${data.header.subtitle}</div>` : ''}
          </div>
        </div>
      ` : ''}

      ${data.showSearch ? `
        <div class='${s.searchContainer}'>
          <input type='text' class='${s.searchInput}' placeholder='${data.searchPlaceholder || 'Search'}' />
        </div>
      ` : ''}

      <div class='${s.content}'>
        ${data.sections ? data.sections.map(section => renderSection(section)).join('') : ''}
        ${data.items ? data.items.map(item => renderItem(item)).join('') : ''}
      </div>

      ${data.footer ? `
        <div class='${s.footer}'>
          ${data.footer.items?.map(item => `
            <button class="${s.footerButton}" data-id="${item.id}">
              ${getIcon(item.icon || 'settings')}
            </button>
          `).join('') || ''}
        </div>
      ` : ''}
    </div>
  `
}

// ============================================================================
// Arc Template (Arc Browser)
// ============================================================================

export function renderArcSidebar(data: SidebarData, collapsed = false): string {
  const s = arcStyles
  const sidebarClass = collapsed ? s.sidebarCollapsed : s.sidebar

  const renderItem = (item: SidebarItemData): string => {
    const isSelected = item.selected

    if (collapsed) {
      const itemClass = isSelected ? s.itemCollapsedSelected : s.itemCollapsed
      return `
        <div class='${itemClass}' data-id='${item.id}'>
          <span class="${isSelected ? s.itemFaviconSelected : s.itemFavicon}">
            ${item.icon ? getIcon(item.icon) : ''}
          </span>
          <div class='${s.tooltip}'>${item.label}</div>
        </div>
      `
    }

    const itemClass = isSelected ? s.itemSelected : s.item
    const closeClass = isSelected ? s.itemCloseSelected : s.itemClose

    return `
      <div class='${itemClass} group' data-id='${item.id}'>
        <span class="${isSelected ? s.itemFaviconSelected : s.itemFavicon}">
          ${item.icon ? getIcon(item.icon) : ''}
        </span>
        <span class='${s.itemLabel}'>${item.label}</span>
        <button class='${closeClass}'>${icons.x}</button>
      </div>
    `
  }

  const renderSpace = (section: SidebarSectionData): string => {
    const color = s.spaceColors[(section as any).color as keyof typeof s.spaceColors] || s.spaceColors.purple
    return `
      <div class='${s.space}'>
        <div class='${s.spaceHeader}' data-space='${section.id}'>
          <div class='${color} ${s.spaceIcon}'>${section.title?.[0] || '•'}</div>
          ${!collapsed ? `
            <span class='${s.spaceName}'>${section.title}</span>
            <span class='${s.spaceCount}'>${section.items.length}</span>
          ` : ''}
        </div>
        ${!section.collapsed ? section.items.map(item => renderItem(item)).join('') : ''}
      </div>
    `
  }

  return `
    <div class='${sidebarClass}'>
      <div class='${s.topBar}'>
        <button class='${s.collapseButton}' id='arc-collapse-toggle'>
          ${icons.menu}
        </button>
        ${!collapsed ? `
          <button class='${s.newTabButton}'>
            ${icons.plus}
          </button>
        ` : ''}
      </div>

      <div class='${s.content}'>
        ${data.sections?.[0]?.title === 'Pinned' ? `
          <div class='${s.pinnedSection}'>
            ${!collapsed ? `<div class="${s.pinnedLabel}">Pinned</div>` : ''}
            ${data.sections[0].items.map(item => renderItem(item)).join('')}
          </div>
        ` : ''}

        ${data.sections?.slice(data.sections[0]?.title === 'Pinned' ? 1 : 0).map(section => renderSpace(section)).join('') || ''}
        ${data.items ? data.items.map(item => renderItem(item)).join('') : ''}
      </div>

      <div class='${s.bottomBar}'>
        ${!collapsed ? `
          <button class='${s.bottomButton}'>
            ${icons.download}
            <span>Downloads</span>
          </button>
        ` : `
          <button class='${s.collapseButton}'>
            ${icons.download}
          </button>
        `}
      </div>
    </div>
  `
}

// ============================================================================
// OrbStack Template (Dark Minimal)
// ============================================================================

export function renderOrbStackSidebar(data: SidebarData): string {
  const s = orbstackStyles

  const renderItem = (item: SidebarItemData): string => {
    const isSelected = item.selected
    const itemClass = isSelected ? s.itemSelected : s.item
    const iconClass = isSelected ? s.itemIconSelected : s.itemIcon

    const hasIndicator = item.status && item.status !== 'none'
    const indicatorClass = item.status === 'running' ? s.runningIndicator : s.stoppedIndicator

    return `
      <div class='${itemClass} group' data-id='${item.id}' ${hasIndicator ? `style='padding-left: 20px'` : ''}>
        ${hasIndicator ? `<div class='${indicatorClass}'></div>` : ''}
        <span class='${iconClass}'>${getIcon(item.icon || 'container')}</span>
        <span class='${s.itemLabel}'>${item.label}</span>
        ${item.status ? `<span class='${s.itemStatus}'>${item.status}</span>` : ''}
        <div class='${s.itemActions}'>
          <button class='${s.itemActionButton}'>${icons.settings}</button>
        </div>
      </div>
    `
  }

  const renderSection = (section: SidebarSectionData): string => {
    return `
      <div class='${s.section}'>
        ${section.title ? `
          <div class="${section.collapsible ? s.sectionHeaderClickable : s.sectionHeader}" data-section="${section.id}">
            <span>${section.title}</span>
            ${section.items.length > 0 ? `<span class="${s.sectionCount}">${section.items.length}</span>` : ''}
          </div>
        ` : ''}
        ${!section.collapsed ? section.items.map(item => renderItem(item)).join('') : ''}
      </div>
    `
  }

  const renderGroup = (item: SidebarItemData): string => {
    const chevronClass = item.expanded ? s.groupChevronExpanded : s.groupChevron
    return `
      <div class='${s.group}'>
        <div class='${s.groupHeader}' data-group='${item.id}'>
          <span class='${chevronClass}'>${icons.chevronRight}</span>
          <span class='${s.itemIcon}'>${getIcon(item.icon || 'folder')}</span>
          <span class='${s.itemLabel}'>${item.label}</span>
        </div>
        ${item.expanded && item.children ? `
          <div class='${s.groupContent}'>
            ${item.children.map(child => renderItem(child)).join('')}
          </div>
        ` : ''}
      </div>
    `
  }

  return `
    <div class='${s.sidebar}'>
      <div class='${s.header}'>
        <span class='${s.headerTitle}'>${data.header?.title || 'OrbStack'}</span>
        <button class='${s.headerAction}'>${icons.plus}</button>
      </div>

      <div class='${s.content}'>
        ${data.sections ? data.sections.map(section => renderSection(section)).join('') : ''}
        ${data.items ? data.items.map(item =>
          item.children ? renderGroup(item) : renderItem(item)
        ).join('') : ''}
      </div>

      <div class='${s.footer}'>
        <span class='${s.footerText}'>v4.0.0</span>
        <button class='${s.footerButton}'>${icons.settings}</button>
      </div>
    </div>
  `
}

// ============================================================================
// Demo Data
// ============================================================================

export const tahoeDemoData: SidebarData = {
  header: {
    title: 'MacBook Pro',
    subtitle: '256 GB available',
    avatar: '💻',
  },
  showSearch: true,
  searchPlaceholder: 'Search',
  sections: [
    {
      id: 'favorites',
      title: 'Favorites',
      collapsible: true,
      items: [
        { id: 'airdrop', label: 'AirDrop', icon: 'cloud' },
        { id: 'recents', label: 'Recents', icon: 'document', badge: 12 },
        { id: 'applications', label: 'Applications', icon: 'folder' },
        { id: 'desktop', label: 'Desktop', icon: 'home', selected: true },
        { id: 'documents', label: 'Documents', icon: 'folder' },
        { id: 'downloads', label: 'Downloads', icon: 'download', badge: 3 },
      ],
    },
    {
      id: 'icloud',
      title: 'iCloud',
      collapsible: true,
      items: [
        { id: 'icloud-drive', label: 'iCloud Drive', icon: 'cloud' },
        { id: 'shared', label: 'Shared', icon: 'folder' },
      ],
    },
    {
      id: 'tags',
      title: 'Tags',
      collapsible: true,
      collapsed: true,
      items: [
        { id: 'red', label: 'Red' },
        { id: 'orange', label: 'Orange' },
      ],
    },
  ],
  footer: {
    items: [
      { id: 'settings', label: 'Settings', icon: 'settings' },
    ],
  },
}

export const arcDemoData: SidebarData = {
  sections: [
    {
      id: 'pinned',
      title: 'Pinned',
      items: [
        { id: 'github', label: 'GitHub', icon: 'document', selected: true },
        { id: 'twitter', label: 'Twitter', icon: 'document' },
        { id: 'figma', label: 'Figma', icon: 'document' },
      ],
    },
    {
      id: 'work',
      title: 'Work',
      items: [
        { id: 'slack', label: 'Slack - Acme Inc', icon: 'document' },
        { id: 'notion', label: 'Notion', icon: 'document' },
        { id: 'linear', label: 'Linear', icon: 'document' },
      ],
    },
    {
      id: 'personal',
      title: 'Personal',
      items: [
        { id: 'youtube', label: 'YouTube', icon: 'document' },
        { id: 'spotify', label: 'Spotify', icon: 'document' },
      ],
    },
  ],
}

export const orbstackDemoData: SidebarData = {
  header: {
    title: 'OrbStack',
  },
  sections: [
    {
      id: 'machines',
      title: 'Machines',
      items: [
        { id: 'ubuntu', label: 'ubuntu', icon: 'linux', status: 'running', selected: true },
        { id: 'fedora', label: 'fedora', icon: 'linux', status: 'stopped' },
        { id: 'alpine', label: 'alpine', icon: 'linux', status: 'stopped' },
      ],
    },
    {
      id: 'containers',
      title: 'Containers',
      items: [
        { id: 'postgres', label: 'postgres:15', icon: 'container', status: 'running' },
        { id: 'redis', label: 'redis:7', icon: 'container', status: 'running' },
        { id: 'nginx', label: 'nginx:latest', icon: 'container', status: 'stopped' },
      ],
    },
  ],
}

// ============================================================================
// Full Page Templates (for quick testing)
// ============================================================================

export function getFullPageHTML(sidebarHTML: string, style: 'tahoe' | 'arc' | 'orbstack'): string {
  const bgClass = style === 'orbstack'
    ? 'bg-[#0f0f0f]'
    : 'bg-neutral-50 dark:bg-neutral-900'

  return `
<!DOCTYPE html>
<html lang="en" class="${style === 'orbstack' ? 'dark' : ''}">
<head>
  <meta charset='UTF-8'>
  <meta name='viewport' content='width=device-width, initial-scale=1.0'>
  <title>Craft Sidebar - ${style}</title>
  <script src='https://cdn.tailwindcss.com'></script>
  <style>
    /* Custom scrollbar */
    .scrollbar-thin::-webkit-scrollbar { width: 6px; }
    .scrollbar-thin::-webkit-scrollbar-track { background: transparent; }
    .scrollbar-thin::-webkit-scrollbar-thumb { background: rgba(0,0,0,0.1); border-radius: 3px; }
    .dark .scrollbar-thin::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.1); }
    .scrollbar-none::-webkit-scrollbar { display: none; }

    /* Backdrop blur fallback */
    @supports not (backdrop-filter: blur(1px)) {
      .backdrop-blur-xl { background: rgba(255,255,255,0.95); }
      .dark .backdrop-blur-xl { background: rgba(30,30,30,0.95); }
    }
  </style>
</head>
<body class='flex min-h-screen ${bgClass}'>
  ${sidebarHTML}
  <div class='flex-1 p-8'>
    <div class='text-neutral-400 dark:text-neutral-500'>
      Content area - select items in the sidebar
    </div>
  </div>
  <script>
    // Add click handlers
    document.querySelectorAll('[data-id]').forEach(el => {
      el.addEventListener('click', () => {
        console.log('Selected:', el.dataset.id);
        // You would update selection state here
      });
    });
  </script>
</body>
</html>
`
}

// ============================================================================
// Export
// ============================================================================

const _exports: {
  renderTahoeSidebar: typeof renderTahoeSidebar;
  renderArcSidebar: typeof renderArcSidebar;
  renderOrbStackSidebar: typeof renderOrbStackSidebar;
  tahoeDemoData: typeof tahoeDemoData;
  arcDemoData: typeof arcDemoData;
  orbstackDemoData: typeof orbstackDemoData;
  getFullPageHTML: typeof getFullPageHTML;
  icons: typeof icons;
} = {
  renderTahoeSidebar,
  renderArcSidebar,
  renderOrbStackSidebar,
  tahoeDemoData,
  arcDemoData,
  orbstackDemoData,
  getFullPageHTML,
  icons,
};
export default _exports;
