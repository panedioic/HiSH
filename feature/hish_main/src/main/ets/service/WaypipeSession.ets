import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HgsService, HgsWindowHostService } from 'hgs';
import napi from 'libhish_main.so';
import QemuAgentManager from '../lib/QemuAgentManager';

const TAG = 'HiSH-Waypipe';
const AGENT_OWNER = 'waypipe';

const PUBLISH_LAUNCHER = [
  'set -eu',
  'umask 077',
  'path=/run/hish-wayland',
  'case "$(readlink "$path" 2>/dev/null || true)" in',
  '  /run/hish-wayland.*/launcher) if [ -x "$path" ]; then echo ready; exit 0; fi ;;',
  'esac',
  'test -c /dev/virtio-ports/org.hish.waypipe.0',
  'dir=$(mktemp -d /run/hish-wayland.XXXXXX)',
  'mounted=0',
  'cleanup() {',
  '  if [ "$mounted" -eq 1 ]; then umount "$dir/share" || return; fi',
  '  rm -rf "$dir"',
  '}',
  'trap cleanup EXIT',
  'mkdir "$dir/share"',
  'mount -t 9p -o trans=virtio,version=9p2000.L,ro hishwaypipe "$dir/share"',
  'mounted=1',
  'cp "$dir/share/waypipe" "$dir/waypipe"',
  'cp "$dir/share/launcher" "$dir/launcher"',
  'chmod 700 "$dir/waypipe" "$dir/launcher"',
  'umount "$dir/share"',
  'mounted=0',
  'rmdir "$dir/share"',
  'ln -sT "$dir/launcher" "$path"',
  'trap - EXIT',
  'echo ready',
].join('\n');

function copyRawFile(context: common.UIAbilityContext, resource: string, path: string): void {
  const data = context.resourceManager.getRawFileContentSync(resource);
  const fd = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
  try {
    if (fs.writeSync(fd.fd, data.buffer) !== data.byteLength) throw new Error('Incomplete copy: ' + resource);
  } finally {
    fs.closeSync(fd);
  }
}

export class WaypipeSession {
  private directory: string = '';
  private pending: Promise<string> | null = null;
  private stopping: Promise<void> | null = null;
  private hgsStarted: boolean = false;
  private listener: number = 0;
  private cancelled: boolean = false;

  start(context: common.UIAbilityContext, stage: window.WindowStage): Promise<string> {
    this.stopping = null;
    this.cancelled = false;
    this.pending = this.prepare(context, stage);
    return this.pending;
  }

  private async prepare(context: common.UIAbilityContext, stage: window.WindowStage): Promise<string> {
    try {
      this.directory = fs.mkdtempSync(context.cacheDir + '/wp-XXXXXX');
      const guest = this.directory + '/guest';
      fs.mkdirSync(guest);
      copyRawFile(context, 'hish-waypipe-linux-arm64', guest + '/waypipe');
      copyRawFile(context, 'hish-wayland-run.sh', guest + '/launcher');
      const socketPath = this.directory + '/p';
      HgsWindowHostService.init(context, { abilityName: 'WaylandWindowAbility', pageUrl: 'pages/HgsWindowPage' });
      const session = await HgsWindowHostService.startService(stage, {
        protocols: 'wayland', runtimeDir: this.directory,
        wayland: { socketName: 'w' }, setProcessEnvironment: false
      });
      this.hgsStarted = true;
      if (this.cancelled) return '';
      this.listener = HgsService.create().onEvent(event => {
        if (event.epoch === session.epoch && event.window.protocol === 'wayland' &&
          (event.kind === 'created' || event.kind === 'destroyed')) {
          hilog.info(0, TAG, 'Wayland window %{public}s %{public}s',
            event.kind, event.window.id);
        }
      });
      if (!napi.startWaypipeProxy(this.directory)) throw new Error('Waypipe native child failed to start');
      for (let attempt = 0; attempt < 100 && !this.cancelled; ++attempt) {
        if (fs.accessSync(socketPath)) {
          hilog.warn(0, TAG, 'Waypipe listener ready: %{public}s', socketPath);
          return socketPath;
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 50));
      }
      if (!this.cancelled) throw new Error('Waypipe transport socket did not appear');
      return '';
    } catch (error) {
      hilog.error(0, TAG, 'Waypipe startup failed: %{public}s', String(error));
      await this.release();
      return '';
    }
  }

  async configureGuest(): Promise<void> {
    try {
      for (let attempt = 0; !this.cancelled && attempt < 30; ++attempt) {
        const agent = await QemuAgentManager.acquire(AGENT_OWNER);
        if (agent) {
          try {
            if (this.cancelled) return;
            const result = await agent.execAndGetOutput('/bin/sh', ['-c', PUBLISH_LAUNCHER]);
            if (result?.trim() === 'ready') {
              hilog.info(0, TAG, 'Guest launcher ready: /run/hish-wayland run PROGRAM');
              return;
            }
          } finally {
            await QemuAgentManager.release(AGENT_OWNER);
          }
        }
        if (!this.cancelled) await new Promise<void>((resolve) => setTimeout(resolve, 500));
      }
      if (!this.cancelled) throw new Error('QEMU Guest Agent did not publish /run/hish-wayland');
    } catch (error) {
      hilog.error(0, TAG, 'Wayland guest startup failed: %{public}s', String(error));
    }
  }

  stop(): Promise<void> {
    this.cancelled = true;
    if (this.stopping === null) {
      this.stopping = (this.pending ?? Promise.resolve('')).then(() => this.release());
    }
    return this.stopping;
  }

  private async release(): Promise<void> {
    napi.stopWaypipeProxy();
    if (this.listener) {
      HgsService.create().offEvent(this.listener);
      this.listener = 0;
    }
    if (this.hgsStarted) {
      this.hgsStarted = false;
      try {
        await HgsWindowHostService.stopService();
      } catch (error) {
        hilog.error(0, TAG, 'Wayland stop failed: %{public}s', String(error));
      }
    }
    const dir = this.directory;
    this.directory = '';
    if (dir) {
      try { fs.rmdirSync(dir); } catch (_) {}
    }
  }
}
