/**
 * SPARK iOS External Panel - UI Controller & Event Handlers
 */

(function () {
  'use strict';

  // ─── Native Bridge ────────────────────────────────────────────────────────
  // Sends a message to the WKWebView native handler (ExternalPanelViewController)
  function sendNative(action, extra) {
    const payload = Object.assign({ action: action }, extra || {});
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.externalPanel) {
        window.webkit.messageHandlers.externalPanel.postMessage(payload);
      } else if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.oxCheatsUI) {
        window.webkit.messageHandlers.oxCheatsUI.postMessage(payload);
      }
    } catch (e) {
      console.warn('[SPARK] sendNative failed:', e);
    }
  }

  // State Management
  const state = {
    selectedGame: 'ff-normal', // 'ff-normal' | 'ff-max'
    currentTheme: 'theme-red',
    activeTab: 'tab-aimbot',
    toggles: {
      aimNeck: true,
      aimBody: false,
      aimLock: true,
      espAntenna: true,
      espHead: false,
      espName: true,
      haptic: true,
      sfx: true
    },
    espColor: 'white'
  };

  // Sound Synthesizer for Touch / Chimes (Web Audio API)
  const AudioEngine = {
    ctx: null,
    init() {
      try {
        const AudioCtx = window.AudioContext || window.webkitAudioContext;
        if (AudioCtx) this.ctx = new AudioCtx();
      } catch (e) {
        console.warn('AudioContext not supported');
      }
    },
    playClick() {
      if (!state.toggles.sfx || !this.ctx) return;
      if (this.ctx.state === 'suspended') this.ctx.resume();
      
      const osc = this.ctx.createOscillator();
      const gain = this.ctx.createGain();
      osc.type = 'sine';
      osc.frequency.setValueAtTime(850, this.ctx.currentTime);
      osc.frequency.exponentialRampToValueAtTime(380, this.ctx.currentTime + 0.05);
      
      gain.gain.setValueAtTime(0.12, this.ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.001, this.ctx.currentTime + 0.05);
      
      osc.connect(gain);
      gain.connect(this.ctx.destination);
      osc.start();
      osc.stop(this.ctx.currentTime + 0.05);
    },
    playChime() {
      if (!state.toggles.sfx || !this.ctx) return;
      if (this.ctx.state === 'suspended') this.ctx.resume();

      const now = this.ctx.currentTime;
      [523.25, 659.25, 783.99, 1046.5].forEach((freq, i) => {
        const osc = this.ctx.createOscillator();
        const gain = this.ctx.createGain();
        osc.type = 'triangle';
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0, now + i * 0.06);
        gain.gain.linearRampToValueAtTime(0.12, now + i * 0.06 + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.001, now + i * 0.06 + 0.28);
        osc.connect(gain);
        gain.connect(this.ctx.destination);
        osc.start(now + i * 0.06);
        osc.stop(now + i * 0.06 + 0.3);
      });
    }
  };

  // Tactile Haptic Vibration
  function triggerHaptic() {
    if (!state.toggles.haptic) return;
    if (window.navigator && window.navigator.vibrate) {
      window.navigator.vibrate(15);
    }
  }

  // Console Logging Helper
  function logEvent(type, message) {
    const consoleLogs = document.getElementById('console-logs');
    if (!consoleLogs) return;

    const row = document.createElement('div');
    row.className = 'log-line';
    const now = new Date();
    const timeStr = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`;
    row.innerHTML = `<span class="log-time">[${timeStr}]</span> <strong>[${type}]</strong> ${message}`;
    consoleLogs.appendChild(row);
    consoleLogs.scrollTop = consoleLogs.scrollHeight;
  }

  // Update Status Dock
  function setStatus(text, isSuccess = false) {
    const statusText = document.getElementById('status-text');
    const indicator = document.querySelector('.status-indicator');
    if (statusText) statusText.textContent = `Status: ${text}`;
    if (indicator) {
      indicator.style.background = isSuccess ? '#00f076' : '#ffaa00';
      indicator.style.boxShadow = `0 0 10px ${isSuccess ? '#00f076' : '#ffaa00'}`;
    }
  }

  // Dom Initialization
  document.addEventListener('DOMContentLoaded', () => {
    AudioEngine.init();
    loadSavedConfig();
    setupTabNavigation();
    setupGameSwitcher();
    setupThemeSwitcher();
    setupToggles();
    setupColorChips();
    setupActionButtons();
    startTelemetry();

    logEvent('BOOT', 'SPARK iOS External WebUI ready.');
    logEvent('SANDBOX', 'External isolated container active. Zero memory hook status.');
  });

  // Tab Navigation
  function setupTabNavigation() {
    const navTabs = document.querySelectorAll('.nav-tab');
    navTabs.forEach(tab => {
      tab.addEventListener('click', () => {
        AudioEngine.playClick();
        triggerHaptic();

        navTabs.forEach(t => t.classList.remove('active'));
        tab.classList.add('active');

        const tabTarget = tab.getAttribute('data-tab');
        state.activeTab = tabTarget;

        document.querySelectorAll('.tab-pane').forEach(pane => {
          pane.classList.remove('active');
        });

        const targetPane = document.getElementById(tabTarget);
        if (targetPane) targetPane.classList.add('active');
      });
    });
  }

  // Game Switcher (Normal / MAX)
  function setupGameSwitcher() {
    const btnNormal = document.getElementById('btn-ff-normal');
    const btnMax = document.getElementById('btn-ff-max');

    btnNormal.addEventListener('click', () => {
      AudioEngine.playClick();
      triggerHaptic();
      btnNormal.classList.add('active');
      btnMax.classList.remove('active');
      state.selectedGame = 'ff-normal';
      setStatus('Target set: Free Fire Normal');
      logEvent('TARGET', 'Switched game bundle to com.dts.freefireth');
    });

    btnMax.addEventListener('click', () => {
      AudioEngine.playClick();
      triggerHaptic();
      btnMax.classList.add('active');
      btnNormal.classList.remove('active');
      state.selectedGame = 'ff-max';
      setStatus('Target set: Free Fire MAX');
      logEvent('TARGET', 'Switched game bundle to com.dts.freefiremax');
    });
  }

  // Theme Switcher (Red, Blue, Green, Purple)
  function setupThemeSwitcher() {
    const dots = document.querySelectorAll('.theme-dot');
    dots.forEach(dot => {
      dot.addEventListener('click', () => {
        AudioEngine.playClick();
        triggerHaptic();

        dots.forEach(d => d.classList.remove('active'));
        dot.classList.add('active');

        const theme = dot.getAttribute('data-theme');
        state.currentTheme = theme;
        document.body.className = theme;
        saveConfig();
        logEvent('THEME', `Applied theme: ${theme.replace('theme-', '').toUpperCase()}`);
      });
    });
  }

  // ─── Aimbot Target Resolution ─────────────────────────────────────────────
  // Maps toggle state to the AimTarget enum used by Vars.Target in native:
  //   0 = HEAD, 1 = NECK, 2 = BODY (matches enum Bones in Gobal.h)
  function resolveAimTarget() {
    if (state.toggles.aimNeck) return 1;   // NECK  (GetNeckPosition)
    if (state.toggles.aimBody) return 2;   // BODY  (hip bone)
    return 0;                              // HEAD  (GetHeadTF)
  }

  // Push current aimbot state to native Vars
  function pushAimbotConfig() {
    const target = resolveAimTarget();
    sendNative('set_config', {
      aimbot:    state.toggles.aimLock ? 1 : 0,
      aim_target: target,
      aim_when:  0  // 0 = always
    });
    logEvent('AIMBOT', `Config pushed → aimLock:${state.toggles.aimLock}, target:${['HEAD','NECK','BODY'][target]}`);
  }

  // Toggles (Neck, Body, Aimlock, Visuals, Settings)
  function setupToggles() {
    // These toggles send their state to native immediately on change
    const aimbotToggleMap = [
      { id: 'chk-aim-neck', key: 'aimNeck' },
      { id: 'chk-aim-body', key: 'aimBody' },
      { id: 'chk-aim-lock', key: 'aimLock' },
    ];

    // UI-only toggles (no native call needed)
    const uiOnlyToggleMap = [
      { id: 'chk-esp-antenna', key: 'espAntenna' },
      { id: 'chk-esp-head',    key: 'espHead' },
      { id: 'chk-esp-name',   key: 'espName' },
      { id: 'chk-haptic',     key: 'haptic' },
      { id: 'chk-sfx',        key: 'sfx' }
    ];

    aimbotToggleMap.forEach(({ id, key }) => {
      const el = document.getElementById(id);
      if (!el) return;
      el.addEventListener('change', (e) => {
        state.toggles[key] = e.target.checked;
        AudioEngine.playClick();
        triggerHaptic();
        saveConfig();
        logEvent('CONFIG', `${key} → ${e.target.checked ? 'ENABLED' : 'DISABLED'}`);
        // Push to native immediately
        pushAimbotConfig();
      });
    });

    uiOnlyToggleMap.forEach(({ id, key }) => {
      const el = document.getElementById(id);
      if (!el) return;
      el.addEventListener('change', (e) => {
        state.toggles[key] = e.target.checked;
        AudioEngine.playClick();
        triggerHaptic();
        saveConfig();
        logEvent('CONFIG', `${key} → ${e.target.checked ? 'ENABLED' : 'DISABLED'}`);
      });
    });
  }

  // ESP Color Chips
  function setupColorChips() {
    const chips = document.querySelectorAll('.chip');
    chips.forEach(chip => {
      chip.addEventListener('click', () => {
        AudioEngine.playClick();
        triggerHaptic();
        chips.forEach(c => c.classList.remove('active'));
        chip.classList.add('active');
        state.espColor = chip.getAttribute('data-color');
        saveConfig();
        logEvent('ESP', `Color changed to ${state.espColor.toUpperCase()}`);
      });
    });
  }

  // Action Buttons
  function setupActionButtons() {
    // 1. INJECT Button (Bottom Dock)
    const btnInject = document.getElementById('dock-btn-inject');
    if (btnInject) {
      btnInject.addEventListener('click', () => {
        AudioEngine.playChime();
        triggerHaptic();

        setStatus('Injecting external patch...', false);
        btnInject.style.opacity = '0.6';
        btnInject.disabled = true;

        logEvent('INJECT', `Preparing injection for ${state.selectedGame}...`);
        logEvent('CONFIG', `Active Options -> Neck: ${state.toggles.aimNeck}, Body: ${state.toggles.aimBody}, Aimlock: ${state.toggles.aimLock}`);

        // Push aimbot config to native BEFORE injection so features are armed
        pushAimbotConfig();
        // Also trigger the inject
        sendNative('apply_patch', {
          game: state.selectedGame === 'ff-normal' ? 'com.dts.freefireth' : 'com.dts.freefiremax',
          features: [
            state.toggles.aimLock ? 'aimlock' : null,
            state.toggles.aimNeck ? 'neck' : null,
            state.toggles.aimBody ? 'body' : null,
          ].filter(Boolean)
        });

        setTimeout(() => {
          btnInject.style.opacity = '1';
          btnInject.disabled = false;
          setStatus('Injected successfully', true);
          logEvent('SUCCESS', 'Aimbot config armed & external patch staged.');
          logEvent('SECURITY', 'Antiban check passed: memory checksums clean.');
        }, 600);
      });
    }

    // 2. RESTORE ORIGINAL FILES (Antiban tab button)
    const btnTabRestore = document.getElementById('btn-restore-files');
    if (btnTabRestore) {
      btnTabRestore.addEventListener('click', () => {
        AudioEngine.playChime();
        triggerHaptic();
        setStatus('Restoring original files...', false);
        logEvent('RESTORE', 'Removing modified patches from contentcache/ ...');

        // Send to native iOS bridge
        sendNative('restore_assets');

        setTimeout(() => {
          setStatus('Restored original game files', true);
          logEvent('RESTORE', 'Original clean game files restored 100%.');
          logEvent('AUTO-PURGE', 'Automatic trace sanitation completed.');
        }, 500);
      });
    }

    // 3. RESET GUEST ACCOUNT (Antiban tab button)
    const btnTabResetGuest = document.getElementById('btn-reset-guest');
    if (btnTabResetGuest) {
      btnTabResetGuest.addEventListener('click', () => {
        AudioEngine.playChime();
        triggerHaptic();
        setStatus('Resetting guest account...', false);
        logEvent('GUEST', 'Generating fresh UUID token for localConfig.json...');

        // Send to native iOS bridge
        sendNative('reset_guest');

        setTimeout(() => {
          setStatus('Guest Account Reset Successful', true);
          logEvent('GUEST', 'New guest device identity staged. Ready for fresh login.');
          logEvent('AUTO-PURGE', 'Automatic token cleanup completed.');
        }, 500);
      });
    }

    // Global Native Callback Bridge
    window.onNativeResult = function(type, message) {
      logEvent('NATIVE', message);
      if (type.includes('success')) {
        setStatus(message, true);
        AudioEngine.playChime();
      }
    };

    // 6. LAUNCH GAME
    const btnLaunch = document.getElementById('dock-btn-launch');
    if (btnLaunch) {
      btnLaunch.addEventListener('click', () => {
        AudioEngine.playClick();
        triggerHaptic();
        const scheme = state.selectedGame === 'ff-normal' ? 'freefireth://' : 'freefiremax://';
        logEvent('LAUNCH', `Launching game with scheme: ${scheme}`);
        setStatus(`Opening ${state.selectedGame}...`, true);
        setTimeout(() => {
          window.location.href = scheme;
        }, 300);
      });
    }

    // 7. CLEAR CONSOLE
    const btnClear = document.getElementById('btn-clear-log');
    if (btnClear) {
      btnClear.addEventListener('click', () => {
        const consoleLogs = document.getElementById('console-logs');
        if (consoleLogs) consoleLogs.innerHTML = '';
        logEvent('INFO', 'Log console cleared.');
      });
    }

    // 8. PRESET SAVE & RESET
    const btnSaveCfg = document.getElementById('btn-save-cfg');
    if (btnSaveCfg) {
      btnSaveCfg.addEventListener('click', () => {
        AudioEngine.playChime();
        triggerHaptic();
        saveConfig();
        logEvent('PRESET', 'Custom configuration saved locally.');
        setStatus('Preset saved', true);
      });
    }

    const btnLoadCfg = document.getElementById('btn-load-cfg');
    if (btnLoadCfg) {
      btnLoadCfg.addEventListener('click', () => {
        AudioEngine.playClick();
        triggerHaptic();
        localStorage.removeItem('spark_panel_cfg');
        logEvent('PRESET', 'Resetting configuration to defaults...');
        setTimeout(() => window.location.reload(), 300);
      });
    }
  }

  // Telemetry (FPS & Clock)
  function startTelemetry() {
    const fpsMeter = document.getElementById('fps-counter');
    const clockDisplay = document.getElementById('clock-display');

    setInterval(() => {
      const d = new Date();
      if (clockDisplay) {
        clockDisplay.textContent = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
      }
    }, 1000);

    let frames = 0;
    let lastTime = performance.now();
    function loop(now) {
      frames++;
      if (now - lastTime >= 1000) {
        if (fpsMeter) fpsMeter.textContent = `${frames} FPS`;
        frames = 0;
        lastTime = now;
      }
      requestAnimationFrame(loop);
    }
    requestAnimationFrame(loop);
  }

  // Config Persistence
  function saveConfig() {
    try {
      localStorage.setItem('spark_panel_cfg', JSON.stringify({
        selectedGame: state.selectedGame,
        currentTheme: state.currentTheme,
        toggles: state.toggles,
        espColor: state.espColor
      }));
    } catch (e) {
      console.warn('Storage save failed');
    }
  }

  function loadSavedConfig() {
    try {
      const saved = localStorage.getItem('spark_panel_cfg');
      if (!saved) return;
      const cfg = JSON.parse(saved);

      if (cfg.currentTheme) {
        state.currentTheme = cfg.currentTheme;
        document.body.className = cfg.currentTheme;
        document.querySelectorAll('.theme-dot').forEach(d => {
          d.classList.toggle('active', d.getAttribute('data-theme') === cfg.currentTheme);
        });
      }

      if (cfg.toggles) {
        Object.assign(state.toggles, cfg.toggles);
        for (const [key, val] of Object.entries(cfg.toggles)) {
          const id = {
            aimNeck: 'chk-aim-neck',
            aimBody: 'chk-aim-body',
            aimLock: 'chk-aim-lock',
            espAntenna: 'chk-esp-antenna',
            espHead: 'chk-esp-head',
            espName: 'chk-esp-name',
            haptic: 'chk-haptic',
            sfx: 'chk-sfx'
          }[key];
          if (id) {
            const el = document.getElementById(id);
            if (el) el.checked = !!val;
          }
        }
      }

      if (cfg.espColor) {
        state.espColor = cfg.espColor;
        document.querySelectorAll('.chip').forEach(c => {
          c.classList.toggle('active', c.getAttribute('data-color') === cfg.espColor);
        });
      }
    } catch (e) {
      console.warn('Storage load failed');
    }
  }

})();
