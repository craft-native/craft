/**
 * Arc Browser Style Example
 * A browser-like app with Arc's vertical tab sidebar
 *
 * Features:
 * - Collapsible tab sections (Pinned, Today)
 * - Gradient hover/selection states
 * - Close buttons on hover
 * - New tab button
 * - Space selector at bottom
 */

import { createApp } from 'craft-native'

const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Arc Browser</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
      height: 100vh;
      display: flex;
      background: #1e1e22;
      color: white;
      overflow: hidden;
    }

    /* ==================== SIDEBAR ==================== */
    .sidebar {
      width: 260px;
      height: 100%;
      display: flex;
      flex-direction: column;
      background: linear-gradient(180deg, #2a2a2e 0%, #1a1a1e 100%);
      border-right: 1px solid rgba(255, 255, 255, 0.06);
      padding: 0.75rem;
      user-select: none;
    }

    /*
      Window controls area.

      The buttons themselves are AppKit's, not ours. This window hides its
      titlebar, so macOS floats the real close/minimise/zoom buttons over the
      top-left of the sidebar — drawing replicas here would put six circles in
      the corner, three of which do nothing. All this strip does is leave them
      room and stay draggable.

      Craft measures the real buttons and publishes the room to leave as the
      --craft-window-controls-width variable used below: their far edge where
      they overlay the page, and 0 where they do not — a window with its own
      titlebar, fullscreen, or this page opened in a browser, which is what the
      fallback is for.

      (No backticks in this comment: the whole document is a template literal.)
    */
    .window-controls {
      height: 38px;
      padding-left: var(--craft-window-controls-width, 0px);
      -webkit-app-region: drag;
    }

    /* Search bar */
    .search-bar {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.625rem 0.75rem;
      margin: 0.5rem 0;
      background: rgba(255, 255, 255, 0.06);
      border-radius: 8px;
      cursor: text;
      transition: background 0.15s;
    }

    .search-bar:hover {
      background: rgba(255, 255, 255, 0.08);
    }

    .search-bar:focus-within {
      background: rgba(255, 255, 255, 0.1);
      outline: 1px solid rgba(99, 102, 241, 0.5);
    }

    .search-bar .icon {
      color: rgba(255, 255, 255, 0.4);
      font-size: 14px;
    }

    .search-bar input {
      flex: 1;
      background: none;
      border: none;
      color: white;
      font-size: 13px;
      outline: none;
    }

    .search-bar input::placeholder {
      color: rgba(255, 255, 255, 0.35);
    }

    /* Tab sections */
    .tab-section {
      margin-bottom: 0.75rem;
    }

    .section-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.5rem;
      font-size: 11px;
      font-weight: 600;
      color: rgba(255, 255, 255, 0.4);
      text-transform: uppercase;
      letter-spacing: 0.5px;
      cursor: pointer;
      border-radius: 6px;
      transition: all 0.15s;
    }

    .section-header:hover {
      color: rgba(255, 255, 255, 0.6);
      background: rgba(255, 255, 255, 0.04);
    }

    .section-header .chevron {
      font-size: 10px;
      transition: transform 0.2s;
    }

    .tab-section.collapsed .chevron {
      transform: rotate(-90deg);
    }

    .tab-section.collapsed .tabs {
      display: none;
    }

    /* Tab items */
    .tab {
      display: flex;
      align-items: center;
      gap: 0.625rem;
      padding: 0.5rem 0.75rem;
      margin: 2px 0;
      border-radius: 8px;
      cursor: pointer;
      transition: all 0.15s ease;
      font-size: 13px;
      color: rgba(255, 255, 255, 0.8);
      position: relative;
    }

    .tab:hover {
      background: linear-gradient(90deg, rgba(99, 102, 241, 0.15) 0%, rgba(168, 85, 247, 0.15) 100%);
    }

    .tab.selected {
      background: linear-gradient(90deg, rgba(99, 102, 241, 0.25) 0%, rgba(168, 85, 247, 0.25) 100%);
      color: white;
    }

    .tab .favicon {
      width: 20px;
      height: 20px;
      border-radius: 4px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 11px;
      font-weight: 600;
      flex-shrink: 0;
    }

    .tab .title {
      flex: 1;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .tab .close {
      opacity: 0;
      width: 18px;
      height: 18px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 14px;
      color: rgba(255, 255, 255, 0.4);
      border-radius: 4px;
      transition: all 0.15s;
      flex-shrink: 0;
    }

    .tab:hover .close {
      opacity: 1;
    }

    .tab .close:hover {
      background: rgba(255, 255, 255, 0.1);
      color: white;
    }

    /* New tab button */
    .new-tab {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 0.5rem;
      padding: 0.625rem;
      margin-top: 0.5rem;
      border-radius: 8px;
      border: 1px dashed rgba(255, 255, 255, 0.12);
      color: rgba(255, 255, 255, 0.4);
      font-size: 12px;
      cursor: pointer;
      transition: all 0.2s;
    }

    .new-tab:hover {
      border-color: rgba(99, 102, 241, 0.4);
      color: rgba(255, 255, 255, 0.7);
      background: rgba(99, 102, 241, 0.1);
    }

    /* Tabs container */
    .tabs-container {
      flex: 1;
      overflow-y: auto;
      overflow-x: hidden;
    }

    .tabs-container::-webkit-scrollbar {
      width: 6px;
    }

    .tabs-container::-webkit-scrollbar-track {
      background: transparent;
    }

    .tabs-container::-webkit-scrollbar-thumb {
      background: rgba(255, 255, 255, 0.15);
      border-radius: 3px;
    }

    /* Spaces (bottom) */
    .spaces {
      border-top: 1px solid rgba(255, 255, 255, 0.08);
      padding-top: 0.75rem;
      margin-top: 0.5rem;
    }

    .space-selector {
      display: flex;
      gap: 0.375rem;
    }

    .space {
      flex: 1;
      height: 36px;
      border-radius: 8px;
      cursor: pointer;
      transition: all 0.15s;
      position: relative;
      overflow: hidden;
    }

    .space::before {
      content: '';
      position: absolute;
      inset: 0;
      opacity: 0.6;
      border-radius: 8px;
    }

    .space.purple::before { background: linear-gradient(135deg, #6366f1, #a855f7); }
    .space.blue::before { background: linear-gradient(135deg, #3b82f6, #06b6d4); }
    .space.green::before { background: linear-gradient(135deg, #22c55e, #84cc16); }
    .space.orange::before { background: linear-gradient(135deg, #f97316, #eab308); }

    .space:hover::before {
      opacity: 0.8;
    }

    .space.selected {
      outline: 2px solid white;
      outline-offset: -2px;
    }

    .space.selected::before {
      opacity: 1;
    }

    /* ==================== MAIN CONTENT ==================== */
    .main {
      flex: 1;
      display: flex;
      flex-direction: column;
      background: #1a1a1e;
    }

    /* URL bar */
    .url-bar {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 0.75rem 1rem;
      background: rgba(255, 255, 255, 0.03);
      border-bottom: 1px solid rgba(255, 255, 255, 0.06);
      -webkit-app-region: drag;
    }

    .nav-buttons {
      display: flex;
      gap: 0.25rem;
      -webkit-app-region: no-drag;
    }

    .nav-btn {
      width: 28px;
      height: 28px;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 6px;
      color: rgba(255, 255, 255, 0.5);
      cursor: pointer;
      transition: all 0.15s;
    }

    .nav-btn:hover {
      background: rgba(255, 255, 255, 0.08);
      color: white;
    }

    .nav-btn.disabled {
      opacity: 0.3;
      pointer-events: none;
    }

    .url-input {
      flex: 1;
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.5rem 0.75rem;
      background: rgba(255, 255, 255, 0.06);
      border-radius: 8px;
      -webkit-app-region: no-drag;
    }

    .url-input .lock {
      color: #22c55e;
      font-size: 12px;
    }

    .url-input input {
      flex: 1;
      background: none;
      border: none;
      color: rgba(255, 255, 255, 0.8);
      font-size: 13px;
      outline: none;
    }

    /* Page content */
    .page-content {
      flex: 1;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 2rem;
    }

    .page-content h1 {
      font-size: 3rem;
      font-weight: 700;
      margin-bottom: 1rem;
      background: linear-gradient(90deg, #6366f1, #a855f7);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }

    .page-content p {
      color: rgba(255, 255, 255, 0.5);
      font-size: 1.125rem;
      text-align: center;
      max-width: 400px;
    }
  </style>
</head>
<body>
  <aside class="sidebar">
    <div class="window-controls"></div>

    <div class="search-bar">
      <span class="icon">🔍</span>
      <input type="text" placeholder="Search or enter URL...">
    </div>

    <div class="tabs-container">
      <div class="tab-section">
        <div class="section-header" onclick="toggleSection(this)">
          <span>Pinned</span>
          <span class="chevron">▼</span>
        </div>
        <div class="tabs">
          <div class="selected tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #ea4335; color: white;">G</span>
            <span class="title">Gmail</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #1da1f2; color: white;">𝕏</span>
            <span class="title">Twitter / X</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #5865f2; color: white;">D</span>
            <span class="title">Discord</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #ff0000; color: white;">▶</span>
            <span class="title">YouTube</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
        </div>
      </div>

      <div class="tab-section">
        <div class="section-header" onclick="toggleSection(this)">
          <span>Today</span>
          <span class="chevron">▼</span>
        </div>
        <div class="tabs">
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #333; color: white;">📝</span>
            <span class="title">Notion - Project Notes</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #24292e; color: white;">⬡</span>
            <span class="title">GitHub - craft/craft</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #ff4500; color: white;">r/</span>
            <span class="title">Reddit - r/programming</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #1db954; color: white;">🎵</span>
            <span class="title">Spotify - Discover Weekly</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
          <div class="tab" onclick="selectTab(this)">
            <span class="favicon" style="background: #0a66c2; color: white;">in</span>
            <span class="title">LinkedIn</span>
            <span class="close" onclick="closeTab(event)">×</span>
          </div>
        </div>
      </div>

      <div class="new-tab" onclick="createTab()">
        <span>+</span>
        <span>New Tab</span>
      </div>
    </div>

    <div class="spaces">
      <div class="space-selector">
        <div class="selected purple space" onclick="selectSpace(this)"></div>
        <div class="blue space" onclick="selectSpace(this)"></div>
        <div class="green space" onclick="selectSpace(this)"></div>
        <div class="orange space" onclick="selectSpace(this)"></div>
      </div>
    </div>
  </aside>

  <main class="main">
    <div class="url-bar">
      <div class="nav-buttons">
        <div class="disabled nav-btn">←</div>
        <div class="disabled nav-btn">→</div>
        <div class="nav-btn">↻</div>
      </div>
      <div class="url-input">
        <span class="lock">🔒</span>
        <input type="text" value="mail.google.com" readonly>
      </div>
    </div>
    <div class="page-content">
      <h1>Arc Browser</h1>
      <p>A vertical tab sidebar built with Craft, inspired by Arc's beautiful gradient design.</p>
    </div>
  </main>

  <script>
    function toggleSection(header) {
      header.parentElement.classList.toggle('collapsed');
    }

    function selectTab(tab) {
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('selected'));
      tab.classList.add('selected');

      // Update URL bar based on selected tab
      const title = tab.querySelector('.title').textContent;
      const urlInput = document.querySelector('.url-input input');
      const urls = {
        'Gmail': 'mail.google.com',
        'Twitter / X': 'twitter.com',
        'Discord': 'discord.com',
        'YouTube': 'youtube.com',
        'Notion - Project Notes': 'notion.so/project-notes',
        'GitHub - craft/craft': 'github.com/craft/craft',
        'Reddit - r/programming': 'reddit.com/r/programming',
        'Spotify - Discover Weekly': 'open.spotify.com/playlist/discover-weekly',
        'LinkedIn': 'linkedin.com/feed',
      };
      urlInput.value = urls[title] || 'example.com';
    }

    function closeTab(event) {
      event.stopPropagation();
      const tab = event.target.closest('.tab');
      const wasSelected = tab.classList.contains('selected');
      const sibling = tab.nextElementSibling || tab.previousElementSibling;

      tab.style.opacity = '0';
      tab.style.transform = 'translateX(-10px)';
      setTimeout(() => {
        tab.remove();
        if (wasSelected && sibling && sibling.classList.contains('tab')) {
          selectTab(sibling);
        }
      }, 150);
    }

    function createTab() {
      const todayTabs = document.querySelectorAll('.tab-section')[1].querySelector('.tabs');
      const newTab = document.createElement('div');
      newTab.className = 'tab';
      newTab.onclick = function() { selectTab(this); };
      newTab.innerHTML = \`
        <span class="favicon" style="background: #333; color: white;">🌐</span>
        <span class="title">New Tab</span>
        <span class="close" onclick="closeTab(event)">×</span>
      \`;
      todayTabs.appendChild(newTab);
      selectTab(newTab);
    }

    function selectSpace(space) {
      document.querySelectorAll('.space').forEach(s => s.classList.remove('selected'));
      space.classList.add('selected');
    }

    console.log('[Arc Browser] Demo loaded');
  </script>
</body>
</html>
`

const app = createApp({
  html,
  window: {
    title: 'Arc Browser',
    width: 1200,
    height: 800,
    titlebarHidden: true,
  },
})

await app.show()
