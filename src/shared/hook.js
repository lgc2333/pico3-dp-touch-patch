/*
 * hook.js —— 在头显本地把电容触摸注入 DP 串流的 HID 报文
 *
 * 用法（设备端，root）：
 *   frida-inject -p $(pidof pxrstreamingservice) -s /data/local/tmp/hook.js -e
 *
 * 原理（全部实测验证）：
 *   pxrstreamingservice 里 GetControllerKeyData 拿到 controller_data_t，
 *   其中 +32 = A/X 触摸、+36 = B/Y 触摸、+40 = 摇杆顶触摸、+44 = 扳机触摸；
 *   同一个进程里 HidIOListener::hidWrite 组装 63 字节报告体。
 *   把触摸位写进报告体的键值字低字节（= USB report[50]）：
 *     bit1 → /input/a/touch      bit3 → /input/b/touch
 *     bit5 → /input/trigger/touch（需驱动补丁）  bit7 → /input/joystick/touch（需驱动补丁）
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
