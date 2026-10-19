#!/system/bin/sh
# sleeper.sh -- a do-nothing stand-in bind-mounted over a vendor/system HAL
# binary that crash-loops in its static constructor under TCG. It just sleeps.
#
# init refuses to exec a shell_data_file even in permissive mode, which is
# exactly what we want: the service then stays dead instead of crash-looping and
# eating the single TCG vCPU. Pushed to the guest and bind-mounted by the
# bring-up script; binds do not survive a guest reboot.
exec /system/bin/sleep 86400
