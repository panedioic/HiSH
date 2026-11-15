import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HgsService, HgsSession, HgsWindowHostService, HgsX11Options } from 'hgs';
import napi from 'libhish_main.so';
import QemuAgentManager from '../lib/QemuAgentManager';
import appOption from '../model/appOption';

const TAG = 'HiSH-X11';
const AGENT_OWNER = 'x11';

// HGS emits a single FamilyWild Xauthority record. Replace its display number
// with the number derived from the TCP port visible to the guest.
function guestAuthority(path: string, display: number): string {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const size = fs.statSync(file.fd).size;
    if (size < 8 || size > 256) throw new Error('Invalid HGS authority size');
    const bytes = new Uint8Array(size);
    if (fs.readSync(file.fd, bytes.buffer) !== bytes.length ||
      bytes[0] !== 255 || bytes[1] !== 255 || bytes[2] !== 0 || bytes[3] !== 0) {
      throw new Error('Invalid HGS authority record');
    }
    const oldLength = (bytes[4] << 8) | bytes[5];
    if (oldLength === 0 || 6 + oldLength >= bytes.length) {
      throw new Error('Invalid HGS display field');
    }
    const number = util.TextEncoder.create().encodeInto(String(display));
    const converted = new Uint8Array(bytes.length - oldLength + number.length);
    converted.set(bytes.subarray(0, 4));
    converted[4] = 0;
    converted[5] = number.length;
    converted.set(number, 6);
    converted.set(bytes.subarray(6 + oldLength), 6 + number.length);
    return new util.Base64Helper().encodeToStringSync(converted);
  } finally {
    fs.closeSync(file);
  }
}

async function prepareX11(context: common.UIAbilityContext): Promise<HgsX11Options> {
  const dir = context.filesDir + '/x11-p0-resources';
  if (!fs.accessSync(dir)) fs.mkdirSync(dir);
  const archive = dir + '/hgs-x11-res.zip';
  const data = context.resourceManager.getRawFileContentSync('hgs-x11-res.zip');
  const file = fs.openSync(archive, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
  try {
    fs.writeSync(file.fd, data.buffer);
  } finally {
    fs.closeSync(file);
  }
  try {
    await zlib.decompressFile(archive, dir, {});
  } finally {
    fs.unlinkSync(archive);
  }
  return { xkbRoot: dir + '/hgs-x11/xkb', keymapPath: dir + '/hgs-x11/keymap.xkm' };
}

// Publish the cookie and display together for the default VM shell.
const PUBLISH = [
  'set -eu',
  'umask 077',
  'dir=$(mktemp -d /run/hish-x11.XXXXXX)',
  'trap \'rm -rf "$dir"\' EXIT',
  'cat > "$dir/Xauthority"',
  'printf "unset WAYLAND_DISPLAY WAYLAND_SOCKET\nexport DISPLAY=%s XAUTHORITY=%s/Xauthority\n" "$1" "$dir" > "$dir/env"',
  'printf "%s\n" "$2" > "$dir/hish-gui"',
  'chmod 700 "$dir/hish-gui"',
  'ln -sfn "$dir/hish-gui" "$dir/launcher"',
  'mv -Tf "$dir/launcher" /run/hish-gui',
  'ln -sfn "$dir/env" "$dir/current"',
  'mv -Tf "$dir/current" /run/hish-x11.env',
  'trap - EXIT',
].join('\n');

const LAUNCHER = [
  '#!/bin/sh',
  'if [ ! -r /run/hish-x11.env ]; then',
  '  echo "HiSH X11 is unavailable for this user." >&2',
  '  exit 1',
  'fi',
  '. /run/hish-x11.env',
  'case "${1-}" in',
  '  status) printf "DISPLAY=%s\n" "$DISPLAY" ;;',
  '  run) shift; if [ "$#" -eq 0 ]; then echo "Usage: /run/hish-gui run PROGRAM [ARG...]" >&2; exit 2; fi; exec "$@" ;;',
  '  *) echo "Usage: /run/hish-gui {status|run PROGRAM [ARG...]}" >&2; exit 2 ;;',
  'esac',
].join('\n');

export class X11Session {
  private active: boolean = false;
  private pending: Promise<void> | null = null;
  private stopping: Promise<void> = Promise.resolve();
  private listener: number = 0;
  private session: HgsSession | null = null;

  start(context: common.UIAbilityContext, stage: window.WindowStage): void {
    if (this.pending || this.active) return;
    this.active = true;
    AppStorage.setOrCreate(appOption.x11Status, 'starting');
    this.pending = this.run(context, stage);
  }

  stop(): Promise<void> {
    if (this.active) AppStorage.setOrCreate(appOption.x11Status, 'idle');
    this.active = false;
    napi.stopX11Bridge();
    if (this.session) {
      this.session = null;
      this.stopping = HgsWindowHostService.stopService().catch((error: Error) => {
        hilog.error(0, TAG, 'X11 stop failed: %{public}s', String(error));
      });
    }
    if (this.listener) {
      HgsService.create().offEvent(this.listener);
      this.listener = 0;
    }
    return this.stopping;
  }

  private async run(context: common.UIAbilityContext, stage: window.WindowStage): Promise<void> {
    try {
      await this.stopping;
      if (!this.active) return;
      if (!HgsService.create().inspect().capabilities.x11) throw new Error('HGS X11 is not built');
      const x11 = await prepareX11(context);
      if (!this.active) return;
      HgsWindowHostService.init(context);
      const session = await HgsWindowHostService.startService(stage, {
        protocols: 'x11', runtimeDir: context.filesDir + '/x11-p0-runtime',
        composition: 'per-window', setProcessEnvironment: false, x11
      });
      this.session = session;
      if (!this.active) {
        this.stop();
        return;
      }
      const endpoint = session.endpoints.find(item => item.protocol === 'x11');
      if (!endpoint) throw new Error('HGS did not publish an X11 endpoint');
      const port = napi.startX11Bridge(endpoint.socketPath);
      if (!port) throw new Error('Could not start X11 loopback bridge');
      this.listener = HgsService.create().onEvent(event => {
        if (event.epoch !== session.epoch) return;
        if (event.kind === 'backend-disconnected') {
          hilog.error(0, TAG, 'Xwayland disconnected');
          void this.stop();
          AppStorage.setOrCreate(appOption.x11Status, 'failed');
        } else if (event.window.protocol === 'x11') {
          hilog.info(0, TAG, 'window %{public}s %{public}s frame=%{public}s',
            event.kind, event.window.id, String(event.window.framePresented));
        }
      });
      const number = port - 6000;
      const authority = guestAuthority(endpoint.authorityPath, number);
      const display = '10.0.2.2:' + number;
      await this.publish(authority, display);
      if (this.active) {
        AppStorage.setOrCreate(appOption.x11Status, 'ready');
        hilog.info(0, TAG, 'Ready: DISPLAY=%{public}s. Use /run/hish-gui run PROGRAM', display);
      }
    } catch (error) {
      hilog.error(0, TAG, 'X11 startup failed: %{public}s', String(error));
      const failed = this.active;
      await this.stop();
      if (failed) AppStorage.setOrCreate(appOption.x11Status, 'failed');
    } finally {
      this.pending = null;
    }
  }

  private async publish(authority: string, display: string): Promise<void> {
    const manager = QemuAgentManager;
    for (let attempt = 0; this.active && attempt < 30; ++attempt) {
      const agent = await manager.acquire(AGENT_OWNER);
      if (agent) {
        try {
          if (!this.active) return;
          const pid = await agent.exec('/bin/sh', ['-c', PUBLISH, 'hish-x11', display, LAUNCHER], authority);
          if (pid !== null) {
            for (let poll = 0; this.active && poll < 15; ++poll) {
              const status = await agent.execStatus(pid);
              if (status?.exited) {
                const exitCode = status.exitcode;
                if (exitCode === 0) return;
                throw new Error('Guest could not publish X11 environment, exit code ' + exitCode);
              }
              if (!status) break;
              await new Promise<void>((resolve) => setTimeout(resolve, 200));
            }
          }
        } finally {
          await manager.release(AGENT_OWNER);
        }
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 500));
    }
    if (this.active) throw new Error('QEMU Guest Agent did not configure the X11 environment');
  }
}
