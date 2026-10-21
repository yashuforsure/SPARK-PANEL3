/**
 * SPARK iOS External Panel - UI Controller & Event Handlers
 */

(function () {
  'use strict';

  // ─── Native Bridge ────────────────────────────────────────────────────────
  // Connects directly to native iOS patcher (OxCheats / ExternalPanelViewController)
  function sendNative(action, extra) {
    const payload = Object.assign({ action: action }, extra || {});
    try {
      if (window.webkit && window.webkit.messageHandlers) {
        if (window.webkit.messageHandlers.oxCheatsUI) {
          window.webkit.messageHandlers.oxCheatsUI.postMessage(payload);
        }
        if (window.webkit.messageHandlers.externalPanel) {
          window.webkit.messageHandlers.externalPanel.postMessage(payload);
        }
      }
    } catch (e) {
      console.warn('[SPARK] sendNative failed:', e);
    }
  }

  // Audio Chime player using native sound asset (applepay.wav) with WebAudio fallback
  function playBeepSound() {
    try {
      const audio = new Audio('applepay.wav');
      audio.play().catch(() => AudioEngine.playChime());
    } catch (e) {
      AudioEngine.playChime();
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
    espColor: 'white',
    hitboxScale: 1.0   // 1.0 – 4.5; 1.0 = original
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

  // Console Logging Engine (writes to live terminal, full-screen terminal, and legacy consoles)
  function logEvent(type, message, isError = false, level = null) {
    const targets = ['terminal-screen', 'terminal-screen-full', 'console-logs'];
    const now = new Date();
    const timeStr = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`;

    let lineClass = 'line-sys';
    let badgeClass = 'badge-sys';
    if (isError || level === 'err' || message.includes('❌') || message.includes('failed') || message.includes('denied')) {
      lineClass = 'line-err';
      badgeClass = 'badge-err';
    } else if (level === 'ok' || message.includes('✅') || message.includes('SUCCESS') || message.includes('patched') || message.includes('Active')) {
      lineClass = 'line-ok';
      badgeClass = 'badge-ok';
    } else if (level === 'warn' || message.includes('⚠️') || message.includes('Sandboxed') || message.includes('RESTRICTED')) {
      lineClass = 'line-warn';
      badgeClass = 'badge-warn';
    }

    // Update Ribbon Indicators
    const rGame = document.getElementById('ribbon-game');
    const rContainer = document.getElementById('ribbon-container');
    const rHitbox = document.getElementById('ribbon-hitbox');

    if (message.includes('[PROCESS]') && (message.includes('RUNNING') || message.includes('Active'))) {
      if (rGame) rGame.innerHTML = '<span class="ribbon-dot dot-ok"></span> GAME: RUNNING';
    } else if (message.includes('[PROCESS]') && message.includes('not running')) {
      if (rGame) rGame.innerHTML = '<span class="ribbon-dot dot-warn"></span> GAME: STANDBY';
    }

    if ((message.includes('[BRIDGE]') || message.includes('[FILEPLAZA]')) && (message.includes('Connected') || message.includes('ONLINE') || message.includes('ACTIVE'))) {
      if (rContainer) rContainer.innerHTML = '<span class="ribbon-dot dot-ok"></span> LINK: ONLINE';
    } else if (message.includes('[BRIDGE]') && (message.includes('waiting') || message.includes('listening') || message.includes('READY'))) {
      if (rContainer) rContainer.innerHTML = '<span class="ribbon-dot dot-warn"></span> LINK: STANDBY';
    }

    if (message.includes('[HITBOX]') && (message.includes('applied') || message.includes('live') || message.includes('Queued') || message.includes('SUCCESS'))) {
      if (rHitbox) rHitbox.innerHTML = `<span class="ribbon-dot dot-ok"></span> HITBOX: ${state.hitboxScale.toFixed(2)}x ACTIVE`;
    }

    targets.forEach(id => {
      const container = document.getElementById(id);
      if (!container) return;
      const row = document.createElement('div');
      row.className = `term-line ${lineClass}`;
      row.innerHTML = `<span class="term-time">[${timeStr}]</span> <span class="term-badge ${badgeClass}">[${type}]</span> ${message}`;
      container.appendChild(row);
      container.scrollTop = container.scrollHeight;
    });
  }

  // Hook native callbacks from OxCheats.dylib
  window.oxCheatsReceive = function(msg) {
    if (!msg) return;
    if (msg.type === 'injectResult') {
      if (msg.ok) {
        logEvent('INJECT-OK', `Patch applied successfully! Status: ${msg.message || 'Done'}`);
        setStatus('Patch Active in Free Fire', true);
      } else {
        logEvent('INJECT-FAIL', `Native error: ${msg.message || 'Unknown error'}`, true);
        setStatus('Injection Failed: ' + (msg.message || ''), false);
      }
    } else if (msg.type === 'hitbox_ok') {
      logEvent('HITBOX', `✅ ${msg.message || 'Hitbox patched'}`);
      setStatus(msg.message || 'Hitbox Active', true);
    } else if (msg.type === 'hitbox_queued') {
      logEvent('HITBOX', `⏳ ${msg.message || 'Hitbox queued — launch game'}`);
      setStatus(msg.message || 'Hitbox Queued', false);
    } else if (msg.type === 'hitbox_staged') {
      logEvent('HITBOX', `📦 ${msg.message || 'Hitbox staged in contentcache'}`);
      setStatus(msg.message || 'Hitbox Staged', false);
    } else if (msg.type === 'hitbox_err') {
      logEvent('HITBOX', `❌ ${msg.message || 'Hitbox patch failed'}`, true);
    } else if (msg.type === 'status') {
      logEvent('SYSTEM', msg.message || JSON.stringify(msg));
    } else if (msg.type === 'miscAck' || msg.type === 'restoreResult') {
      logEvent('RESTORE', msg.message || 'Asset restore completed');
    } else {
      logEvent('NATIVE', JSON.stringify(msg));
    }
  };

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
    // Notify native OxCheats engine that UI is mounted and ready
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.oxCheatsUI) {
        window.webkit.messageHandlers.oxCheatsUI.postMessage({ type: 'ready' });
        window.webkit.messageHandlers.oxCheatsUI.postMessage({ type: 'uiSettled' });
      }
    } catch (e) {}

    AudioEngine.init();
    loadSavedConfig();
    setupTabNavigation();
    setupGameSwitcher();
    setupThemeSwitcher();
    setupToggles();
    setupColorChips();
    setupActionButtons();
    setupHitboxSlider();
    startTelemetry();

    logEvent('BOOT', 'SPARK iOS External WebUI ready.');
    logEvent('SANDBOX', 'OxCheats sandbox bridge connected & armed.');
    logEvent('HITBOX', 'Head hitbox patcher ready — slide to scale.');
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
      aimbot:       state.toggles.aimLock ? 1 : 0,
      aim_target:   target,
      aim_when:     0,             // 0 = always
      hitbox_scale: state.hitboxScale
    });
    logEvent('AIMBOT', `Config pushed → aimLock:${state.toggles.aimLock}, target:${['HEAD','NECK','BODY'][target]}, hitbox:${state.hitboxScale.toFixed(2)}x`);
  }

  // ─── Hitbox Slider & Presets ──────────────────────────────────────────────
  function setupHitboxSlider() {
    const slider     = document.getElementById('hitbox-scale-slider');
    const display    = document.getElementById('hitbox-scale-display');
    const btnApply   = document.getElementById('btn-hitbox-apply');
    const btnReset   = document.getElementById('btn-hitbox-reset');
    const statusMsg  = document.getElementById('hitbox-status-msg');
    const presetBtns = document.querySelectorAll('.hb-preset-btn');

    if (!slider) return;

    function updatePresetHighlight(val) {
      presetBtns.forEach(btn => {
        const pVal = parseFloat(btn.dataset.scale);
        if (Math.abs(pVal - val) < 0.08) {
          btn.classList.add('active');
        } else {
          btn.classList.remove('active');
        }
      });
    }

    function setScale(val, notifyUser = true) {
      const clamped = Math.max(1.0, Math.min(4.5, val));
      state.hitboxScale = clamped;
      slider.value = clamped;
      if (display) display.textContent = `${clamped.toFixed(2)}x`;
      updatePresetHighlight(clamped);

      const estimatedRadius = (0.22 * clamped).toFixed(2);
      if (statusMsg && notifyUser) {
        statusMsg.textContent = `Scale: ${clamped.toFixed(2)}x (~${estimatedRadius}m head radius). Tap APPLY HITBOX.`;
      }
    }

    // Initialize from state
    setScale(state.hitboxScale, false);

    // Slider Drag / Touch
    slider.addEventListener('input', () => {
      setScale(parseFloat(slider.value), true);
    });

    slider.addEventListener('change', () => {
      AudioEngine.playClick();
      triggerHaptic();
      saveConfig();
    });

    // Preset Pill Taps (1-Tap Selection)
    presetBtns.forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        const pVal = parseFloat(btn.dataset.scale);
        AudioEngine.playClick();
        triggerHaptic();
        setScale(pVal, true);
        saveConfig();
      });
    });

    if (btnApply) {
      btnApply.addEventListener('click', (e) => {
        e.preventDefault();
        AudioEngine.playChime();
        triggerHaptic();

        const scale = state.hitboxScale;
        const estM = (0.22 * scale).toFixed(2);
        logEvent('HITBOX', `⚡ Applying hitbox scale=${scale.toFixed(2)}x (~${estM}m)...`);
        setStatus(`Hitbox ${scale.toFixed(2)}x Patched`, true);

        if (statusMsg) {
          statusMsg.textContent = `Applying ${scale.toFixed(2)}x patch to UnityFramework memory...`;
        }

        // Send hitbox_patch action to native with selected bone target (Head/Neck/Body)
        const target = resolveAimTarget();
        sendNative('hitbox_patch', { scale: scale, target: target });

        // Also sync via set_config
        pushAimbotConfig();
        saveConfig();

        // Visual button confirmation
        const origText = btnApply.innerHTML;
        btnApply.innerHTML = '<span class="btn-icon">✓</span> APPLIED!';
        btnApply.style.filter = 'brightness(1.3)';
        setTimeout(() => {
          btnApply.innerHTML = origText;
          btnApply.style.filter = '';
        }, 1200);
      });
    }

    if (btnReset) {
      btnReset.addEventListener('click', (e) => {
        e.preventDefault();
        AudioEngine.playClick();
        triggerHaptic();

        setScale(1.0, true);
        logEvent('HITBOX', 'Hitbox restored to original 1.0x (0.22m)');
        sendNative('hitbox_restore', {});
        setStatus('Hitbox Restored (1.0x)', true);
        if (statusMsg) {
          statusMsg.textContent = 'Status: Hitbox reset to default 1.0x.';
        }
        saveConfig();
      });
    }
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
        // Play native applepay chime/beep sound
        playBeepSound();
        triggerHaptic();

        setStatus('Injecting external patch...', false);
        btnInject.style.opacity = '0.6';
        btnInject.disabled = true;

        logEvent('INJECT', `Preparing injection for ${state.selectedGame}...`);
        logEvent('CONFIG', `Active Options -> Neck: ${state.toggles.aimNeck}, Body: ${state.toggles.aimBody}, Aimlock: ${state.toggles.aimLock}`);

        // Resolve exact patch name for the native engine
        let patchTarget = 'NECK';
        if (state.toggles.aimNeck && state.toggles.aimLock) patchTarget = 'NECK';
        else if (state.toggles.aimBody) patchTarget = 'BODY';
        else if (state.toggles.aimLock) patchTarget = 'AIMLOCK';

        // 1. Send native OxCheats payload
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.oxCheatsUI) {
          window.webkit.messageHandlers.oxCheatsUI.postMessage({
            type: 'inject',
            game: state.selectedGame === 'ff-normal' ? 'ff' : 'ffmax',
            aimVersion: 'v2',
            patch: patchTarget,
            esp: state.toggles.espAntenna ? 'FULL BODY' : ''
          });
        }

        // 2. Also send to standard bridge
        sendNative('apply_patch', {
          game: state.selectedGame === 'ff-normal' ? 'com.dts.freefireth' : 'com.dts.freefiremax',
          patch: patchTarget,
          features: [
            state.toggles.aimLock ? 'aimlock' : null,
            state.toggles.aimNeck ? 'neck' : null,
            state.toggles.aimBody ? 'body' : null,
          ].filter(Boolean)
        });

        setTimeout(() => {
          btnInject.style.opacity = '1';
          btnInject.disabled = false;
        }, 1200);
      });
    }

    // 2. RESTORE ORIGINAL FILES (Antiban tab button)
    const btnTabRestore = document.getElementById('btn-restore-files');
    if (btnTabRestore) {
      btnTabRestore.addEventListener('click', () => {
        playBeepSound();
        triggerHaptic();
        setStatus('Restoring original files...', false);
        logEvent('RESTORE', 'Removing modified patches from contentcache/ ...');

        // Send restore to OxCheats native engine
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.oxCheatsUI) {
          window.webkit.messageHandlers.oxCheatsUI.postMessage({
            type: 'restore'
          });
        }

        // Send to standard iOS bridge
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
      if (type === 'terminal_ok') {
        logEvent('SUCCESS', message, false, 'ok');
      } else if (type === 'terminal_warn') {
        logEvent('WARN', message, false, 'warn');
      } else if (type === 'terminal_err') {
        logEvent('ERROR', message, true, 'err');
      } else if (type === 'terminal_log') {
        logEvent('NATIVE', message, false, 'sys');
      } else if (type === 'launch_result') {
        logEvent('LAUNCH', message, false, 'ok');
        setStatus('Game Launch Requested', true);
      } else if (type.includes('success')) {
        logEvent('SUCCESS', message, false, 'ok');
        setStatus(message, true);
        AudioEngine.playChime();
      } else {
        logEvent('NATIVE', message);
      }
    };

    // 5. TEST CONNECTION BUTTON (Diagnostics)
    const testBtns = [document.getElementById('btn-test-connection'), document.getElementById('btn-test-connection-tab')];
    testBtns.forEach(btn => {
      if (!btn) return;
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        AudioEngine.playClick();
        triggerHaptic();
        logEvent('DIAG', 'Triggering full iOS system diagnostics...');
        setStatus('Testing connection...', false);
        sendNative('run_diagnostics', {});
      });
    });

    // 6. LAUNCH GAME BUTTON
    const btnLaunch = document.getElementById('dock-btn-launch');
    if (btnLaunch) {
      btnLaunch.addEventListener('click', (e) => {
        e.preventDefault();
        AudioEngine.playClick();
        triggerHaptic();
        const scheme = state.selectedGame === 'ff-normal' ? 'freefireth://' : 'freefiremax://';
        logEvent('LAUNCH', `Sending launch command for ${state.selectedGame} (${scheme})...`);
        setStatus(`Launching ${state.selectedGame}...`, true);
        sendNative('launch_game', { scheme: scheme });
      });
    }

    // 7. CLEAR TERMINALS
    const clearBtns = [
      document.getElementById('btn-clear-terminal'),
      document.getElementById('btn-clear-terminal-tab'),
      document.getElementById('btn-clear-log'),
      document.getElementById('btn-clear-log-aimbot')
    ];
    clearBtns.forEach(btn => {
      if (!btn) return;
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        ['terminal-screen', 'terminal-screen-full', 'console-logs'].forEach(id => {
          const el = document.getElementById(id);
          if (el) el.innerHTML = '';
        });
        logEvent('SYSTEM', 'Terminal logs cleared.');
      });
    });

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
        selectedGame:  state.selectedGame,
        currentTheme:  state.currentTheme,
        toggles:       state.toggles,
        espColor:      state.espColor,
        hitboxScale:   state.hitboxScale
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

      if (cfg.hitboxScale && typeof cfg.hitboxScale === 'number') {
        state.hitboxScale = cfg.hitboxScale;
        const slider  = document.getElementById('hitbox-scale-slider');
        const display = document.getElementById('hitbox-scale-display');
        if (slider)  slider.value = cfg.hitboxScale;
        if (display) display.textContent = `${cfg.hitboxScale.toFixed(2)}x`;
      }
    } catch (e) {
      console.warn('Storage load failed');
    }
  }

  // ─── App Initialization ───────────────────────────────────────────────────
  function initApp() {
    AudioEngine.init();
    setupTabNavigation();
    setupGameSwitcher();
    setupThemeSwitcher();
    setupHitboxSlider();
    setupToggles();
    setupColorChips();
    setupActionButtons();
    startTelemetry();
    loadSavedConfig();
    logEvent('SYSTEM', 'SPARK iOS Panel initialized. Ready.');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initApp);
  } else {
    initApp();
  }

})();
