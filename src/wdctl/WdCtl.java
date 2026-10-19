import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

/**
 * Registers an IActivityController with ActivityManager so that system_server's
 * Watchdog asks us before killing itself; we answer 1 ("keep waiting"). App
 * ANRs get the same answer. Re-registers after a system_server restart.
 *
 * Under single-core TCG a monitored handler can block for the duration of a
 * long interpreted operation, which trips the framework Watchdog. The
 * controller lets the Watchdog log + sysrq but not kill system_server. Pair it
 * with the Watchdog <init> timeout patch (see patches/oat-patches.md); on its
 * own the controller does not stop every kill path.
 *
 * Run as root: CLASSPATH=wdctl.dex app_process64 /system/bin WdCtl
 */
public class WdCtl {
    static final String DESC = "android.app.IActivityController";
    static final String[] NAMES = {"?", "activityStarting", "activityResuming", "appCrashed",
            "appEarlyNotResponding", "appNotResponding", "systemNotResponding"};

    static void log(String s) {
        System.out.println(System.currentTimeMillis() / 1000 + " " + s);
        System.out.flush();
    }

    public static void main(String[] args) throws Exception {
        Binder ctl = new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) {
                    try {
                        return super.onTransact(code, data, reply, flags);
                    } catch (Exception e) {
                        return false;
                    }
                }
                String what = code < NAMES.length ? NAMES[code] : "code " + code;
                if (code >= 3) {
                    // appCrashed/ANR/systemNotResponding: first arg is a String.
                    data.enforceInterface(DESC);
                    log(what + ": " + data.readString());
                }
                if (reply != null) {
                    // bool true for starting/resuming/crashed, int 1 = keep waiting otherwise.
                    reply.writeNoException();
                    reply.writeInt(1);
                }
                return true;
            }
        };
        ctl.attachInterface(null, DESC);

        Class<?> sm = Class.forName("android.os.ServiceManager");
        java.lang.reflect.Method getService = sm.getMethod("getService", String.class);
        java.lang.reflect.Field f = Class.forName("android.app.IActivityManager$Stub")
                .getDeclaredField("TRANSACTION_setActivityController");
        f.setAccessible(true);
        int code = f.getInt(null);

        IBinder am = null;
        while (true) {
            if (am == null || !am.pingBinder()) {
                am = (IBinder) getService.invoke(null, "activity");
                if (am != null) {
                    Parcel d = Parcel.obtain(), r = Parcel.obtain();
                    try {
                        d.writeInterfaceToken("android.app.IActivityManager");
                        d.writeStrongBinder(ctl);
                        d.writeInt(0); // imAMonkey
                        am.transact(code, d, r, 0);
                        r.readException();
                        log("controller set");
                    } catch (Exception e) {
                        log("set failed: " + e);
                        am = null;
                    } finally {
                        d.recycle();
                        r.recycle();
                    }
                }
            }
            Thread.sleep(10000);
        }
    }
}
