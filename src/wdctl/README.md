# WdCtl.java build note

`WdCtl` registers an `IActivityController` that answers the framework Watchdog
"keep waiting" (see the class comment). It is compiled on the host against the
`platforms;android-28` `android.jar` compile-time stubs; the real
`android.os.*` / `android.app.*` classes exist on the guest at runtime.

```sh
AJAR=$SDK_ROOT/platforms/android-28/android.jar
D8=$SDK_ROOT/build-tools/28.0.3/d8
# --release 8 so a modern javac emits Java-8 (v52) bytecode that d8 accepts.
javac --release 8 -cp "$AJAR" -d out/wdctl src/wdctl/WdCtl.java
# WdCtl has an anonymous Binder subclass (WdCtl$1), so dex ALL emitted classes.
"$D8" --min-api 28 --lib "$AJAR" --output out/wdctl out/wdctl/WdCtl*.class
# out/wdctl/classes.dex -> push to the guest as /data/local/tmp/wdctl.dex
```

The resulting `classes.dex` is a build artifact and is never committed.
