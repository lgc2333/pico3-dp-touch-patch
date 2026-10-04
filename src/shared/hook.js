/*
 * hook.js —— 头显端 Frida 脚本：把电容触摸写进 DP 串流的 HID 报文。
 * 用法（设备端，root）：frida-inject -p $(pidof pxrstreamingservice) -s /data/local/tmp/hook.js -e
 * 原理（偏移、位映射、为什么不换行）：见 docs/notes/02-hid-protocol.md、05-injection.md
 */
(function () {
    'use strict';

    const CC = 'libpxrcontrollerclient.pxr.so';   // GetControllerKeyData
    const SS = 'libpxrstreamingservice.so';       // HidIOListener::hidWrite
    const OFF_GETKEYDATA = 0x1f5c4;
    const OFF_HIDWRITE = 0x18014;

    const cc = Process.getModuleByName(CC).base;
    const ss = Process.getModuleByName(SS).base;

    const touch = {};   // hand(1=左 2=右) -> {ax, by, stick, trig}

    Interceptor.attach(cc.add(OFF_GETKEYDATA), {
        onEnter(a) { this.p = a[1]; },
        onLeave(r) {
            try {
                const b = new Uint8Array(this.p.readByteArray(64));
                touch[b[0]] = {
                    ax: b[32] !== 0,     // A / X 电容触摸
                    by: b[36] !== 0,     // B / Y 电容触摸
                    stick: b[40] !== 0,  // 摇杆顶电容触摸
                    trig: b[44] !== 0,   // 扳机电容触摸
                };
            } catch (e) {}
        }
    });

    Interceptor.attach(ss.add(OFF_HIDWRITE), {
        onEnter(a) {
            const p = a[1], n = a[2].toInt32();
            if (n !== 63) return;
            try {
                const b = new Uint8Array(p.readByteArray(63));
                const t = touch[b[1] >> 5];   // 报告 type：1=左 2=右
                if (!t) return;
                const kv = b[49];             // 键值字低字节
                let nv = kv & ~0xAA;          // 先清 bit1/3/5/7
                if (t.ax)    nv |= 0x02;
                if (t.by)    nv |= 0x08;
                if (t.trig)  nv |= 0x20;
                if (t.stick) nv |= 0x80;
                if (nv !== kv) p.add(49).writeU8(nv);
            } catch (e) {}
        }
    });

    send({ ok: true, msg: 'touch hook installed' });
})();
