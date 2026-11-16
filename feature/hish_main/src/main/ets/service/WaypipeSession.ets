import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HgsService, HgsWindowHostService } from 'hgs';
import napi from 'libhish_main.so';

const TAG = 'HiSH-Waypipe';

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
      const binary = context.resourceManager.getRawFileContentSync('hish-waypipe-linux-arm64');
      const fd = fs.openSync(guest + '/waypipe', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      try {
        if (fs.writeSync(fd.fd, binary.buffer) !== binary.byteLength) throw new Error('Waypipe guest copy incomplete');
      } finally {
        fs.closeSync(fd);
      }
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
