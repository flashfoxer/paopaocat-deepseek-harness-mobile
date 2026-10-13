import java.io.*;
import java.nio.charset.StandardCharsets;

/**
 * 验证 LiteRtLmBridge 的 HTTP 正文读取（用 Java 表达同样的 JVM 语义）。
 *
 * 把「旧写法」与「新写法」放进**同一个不会 EOF 的管道**（模拟真实 socket：
 * 客户端发完就等响应、不关连接），看谁会卡死。
 */
public class HttpBodyTest {

    /** 造一个含中文的 POST 请求（模拟 DSH 发来的 /v1/chat/completions）。 */
    static byte[] makeRequest() throws Exception {
        String bodyJson = "{\"model\":\"local\",\"messages\":[{\"role\":\"system\",\"content\":\"你是一个中文助手，请用简体中文回答。\"},{\"role\":\"user\",\"content\":\"你好，请介绍一下你自己。\"}],\"stream\":true,\"max_tokens\":64}";
        byte[] bodyBytes = bodyJson.getBytes(StandardCharsets.UTF_8);
        String head = "POST /v1/chat/completions HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: " + bodyBytes.length + "\r\n"
                + "\r\n";
        byte[] headBytes = head.getBytes(StandardCharsets.US_ASCII);
        byte[] all = new byte[headBytes.length + bodyBytes.length];
        System.arraycopy(headBytes, 0, all, 0, headBytes.length);
        System.arraycopy(bodyBytes, 0, all, headBytes.length, bodyBytes.length);
        return all;
    }

    /** 不关闭的管道（写完保持打开，模拟等待响应的客户端）。 */
    static PipedInputStream pipeOf(byte[] bytes) throws Exception {
        PipedOutputStream out = new PipedOutputStream();
        PipedInputStream in = new PipedInputStream(out, 1 << 20);
        final Object keepAlive = new Object();
        Thread t = new Thread(() -> {
            try {
                out.write(bytes);
                out.flush();
                // ⚠️ 关键：写完**不能让本线程退出** —— PipedInputStream 会发现
                // "write end dead" 而抛 IOException，那样就模拟不出真实 socket 的
                // "客户端还在等响应、连接没关" 这个现象（真实现象是**卡住**）。
                // 所以这里把线程挂住，模拟一个一直等响应的客户端。
                synchronized (keepAlive) {
                    keepAlive.wait();
                }
            } catch (Exception ignored) {
            }
        });
        t.setDaemon(true);
        t.start();
        return in;
    }

    // ── 旧写法（当前生产代码）──────────────────────────────────────────
    static String readOld(InputStream ins) throws Exception {
        BufferedReader input = new BufferedReader(new InputStreamReader(ins, StandardCharsets.UTF_8));
        input.readLine();
        int contentLength = 0;
        while (true) {
            String line = input.readLine();
            if (line == null) break;
            if (line.isEmpty()) break;
            int idx = line.indexOf(':');
            if (idx > 0 && line.substring(0, idx).trim().equalsIgnoreCase("Content-Length")) {
                try {
                    contentLength = Integer.parseInt(line.substring(idx + 1).trim());
                } catch (NumberFormatException e) {
                    contentLength = 0;
                }
            }
        }
        char[] body = new char[contentLength];
        int read = 0;
        while (read < contentLength) {
            int n = input.read(body, read, contentLength - read);
            if (n <= 0) break;
            read += n;
        }
        return new String(body, 0, read);
    }

    // ── 新写法（本次修复：按字节读，再 UTF-8 解码）────────────────────
    static String readNew(InputStream ins) throws Exception {
        BufferedInputStream raw = new BufferedInputStream(ins);
        java.util.List<String> headerLines = new java.util.ArrayList<>();
        StringBuilder sb = new StringBuilder();
        while (true) {
            int b = raw.read();
            if (b < 0) break;
            if (b == '\n') {
                String s = sb.toString();
                sb.setLength(0);
                if (s.endsWith("\r")) s = s.substring(0, s.length() - 1);
                if (s.isEmpty()) break;
                headerLines.add(s);
            } else {
                sb.append((char) b);
            }
        }
        int contentLength = 0;
        for (String h : headerLines) {
            int idx = h.indexOf(':');
            if (idx > 0 && h.substring(0, idx).trim().equalsIgnoreCase("Content-Length")) {
                try {
                    contentLength = Integer.parseInt(h.substring(idx + 1).trim());
                } catch (NumberFormatException e) {
                    contentLength = 0;
                }
            }
        }
        byte[] bodyBytes = new byte[contentLength];
        int read = 0;
        while (read < contentLength) {
            int n = raw.read(bodyBytes, read, contentLength - read);
            if (n <= 0) break;
            read += n;
        }
        return new String(bodyBytes, 0, read, StandardCharsets.UTF_8);
    }

    static final class Result {
        boolean done;
        String text = "";
        long ms;
    }

    /** 在独立线程里跑，2 秒不回就当卡死。 */
    static Result timed(String label, Func f, byte[] bytes) throws Exception {
        Result r = new Result();
        long t0 = System.currentTimeMillis();
        Thread th = new Thread(() -> {
            try {
                r.text = f.apply(pipeOf(bytes));
                r.done = true;
            } catch (Exception e) {
                r.text = "ERR " + e;
            }
        });
        th.setDaemon(true);
        th.start();
        th.join(2000);
        r.ms = System.currentTimeMillis() - t0;
        System.out.println("[" + label + "] 完成=" + r.done + " 线程仍存活(即在阻塞)=" + th.isAlive()
                + " 耗时=" + r.ms + "ms 正文长度=" + r.text.length()
                + (r.done ? "" : " 已读到片段=" + r.text.length() + "字符"));
        return r;
    }

    interface Func {
        String apply(InputStream in) throws Exception;
    }

    public static void main(String[] args) throws Exception {
        byte[] req = makeRequest();
        int bodyBytes = req.length - (new String(req, StandardCharsets.US_ASCII).indexOf("\r\n\r\n") + 4);
        System.out.println("请求总字节=" + req.length + "（含中文 → 字节数(" + bodyBytes + ") > 字符数）");
        System.out.println("---- 旧写法（把 Content-Length 当字符数读）----");
        Result old = timed("旧", HttpBodyTest::readOld, req);
        System.out.println("---- 新写法（按字节读再 UTF-8 解码）----");
        Result neu = timed("新", HttpBodyTest::readNew, req);

        boolean ok = (!old.done) && neu.done && neu.text.contains("你好") && neu.text.contains("中文助手");
        System.out.println();
        System.out.println(ok
                ? "✅ 结论：旧写法会卡死、新写法正确取到完整中文正文 —— bug 复现且修复有效"
                : "❌ 结论不符：old.done=" + old.done + " new.done=" + neu.done);
        System.exit(ok ? 0 : 1);
    }
}
