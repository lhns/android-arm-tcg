import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import java.io.BufferedReader;
import java.io.FileReader;
import java.lang.reflect.Method;

/**
 * Media-service stub for the software-TCG API-28 arm64 guest.
 *
 * Pie SystemServer always starts AudioService, whose systemReady() blocks the
 * system_server MAIN thread "Waiting for service media.audio_policy /
 * media.sound_trigger_hw" before it ever calls ActivityManagerService
 * .systemReady(); StorageManagerService then stays mSystemReady=false. The real
 * media HALs crash in their static constructors under TCG, so nothing registers
 * these names. This process, run as root via app_process64,
 * ServiceManager.addService's each name with a Binder whose onTransact only
 * writes a no-exception header + a zero, then sleeps. That is enough for the
 * waiters to unblock; nothing actually calls the media APIs during bring-up.
 *
 * Do NOT register SurfaceFlinger: a dummy one makes DisplayManagerService time
 * out ("Timeout waiting for default display").
 *
 * svc.list: StorageManagerService.connect() needs BOTH vold and storaged
 * registered or mDaemonConnected stays false ("storaged not found; trying
 * again" forever once storaged is sleeper-bound). The bring-up script writes
 * "storaged" into /data/local/tmp/svc.list; every name there is registered too.
 *
 * Run: CLASSPATH=/data/local/tmp/stub.dex \
 *        app_process64 /system/bin Stub >stub.log 2>&1 &
 * ART startup under TCG takes 1-2 min before the log flushes; check with
 * `service check media.audio_policy`.
 */
public class Stub {
    static final String[] NAMES = {
            "media.audio_policy", "media.audio_flinger", "media.player",
            "media.resource_manager", "media.camera", "media.extractor",
            "media.metrics", "media.sound_trigger_hw", "drm.drmManager"
    };
    static final String SVC_LIST = "/data/local/tmp/svc.list";

    static void log(String s) {
        System.out.println(System.currentTimeMillis() / 1000 + " " + s);
        System.out.flush();
    }

    public static void main(String[] args) throws Exception {
        // One Binder for every name: onTransact answers no-exception + 0 for any
        // code. The media waiters only need the service to exist and reply.
        Binder stub = new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                if (reply != null) {
                    reply.writeNoException();
                    reply.writeInt(0);
                }
                return true;
            }
        };

        Class<?> sm = Class.forName("android.os.ServiceManager");
        Method addService = sm.getMethod("addService", String.class, IBinder.class);

        for (String n : NAMES) register(addService, stub, n);

        // Extra names from svc.list (e.g. storaged), one per line.
        try {
            BufferedReader br = new BufferedReader(new FileReader(SVC_LIST));
            for (String line; (line = br.readLine()) != null; ) {
                line = line.trim();
                if (!line.isEmpty()) register(addService, stub, line);
            }
            br.close();
        } catch (Exception e) {
            log("svc.list: " + e);
        }

        log("stub ready");
        while (true) Thread.sleep(3600000L);
    }

    static void register(Method addService, IBinder stub, String name) {
        try {
            addService.invoke(null, name, stub);
            log("added " + name);
        } catch (Exception e) {
            log("add " + name + " failed: " + e);
        }
    }
}
