import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** 证两件事：① 旧解析（只认 Content-Length）遇到 chunked 请求会得到**空正文** → jsonDecode 必炸；
 *  ② 新解析（认 Transfer-Encoding: chunked）拿到**完整正文**。与 LiteRtLmBridge.kt 的新旧逻辑一一对应。 */
public class ChunkedBodyTest {
  static final String BODY = "{\"model\":\"qwen3-0.6b\",\"messages\":[{\"role\":\"user\","
      + "\"content\":\"用一句话解释什么是黑洞，尽量简短。\"}],\"max_tokens\":48,\"temperature\":0}";

  /** 造一个真实的 chunked 请求（Flutter/Dart HttpClient 用 req.add() 时就是这个形状）。 */
  static byte[] buildRequest() throws IOException {
    ByteArrayOutputStream o = new ByteArrayOutputStream();
    o.write(("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        + "content-type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")
        .getBytes(StandardCharsets.UTF_8));
    byte[] b = BODY.getBytes(StandardCharsets.UTF_8);
    // 故意切成 3 个 chunk，模拟真实分片
    int[] cuts = {37, 41, b.length - 78};
    int off = 0;
    for (int c : cuts) {
      o.write((Integer.toHexString(c) + "\r\n").getBytes(StandardCharsets.US_ASCII));
      o.write(b, off, c); off += c;
      o.write("\r\n".getBytes(StandardCharsets.US_ASCII));
    }
    o.write("0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
    return o.toByteArray();
  }

  static String readAsciiLine(InputStream raw) throws IOException {
    StringBuilder sb = new StringBuilder();
    while (true) {
      int b = raw.read();
      if (b < 0) return sb.length() == 0 ? null : sb.toString();
      if (b == '\n') {
        String s = sb.toString();
        return s.endsWith("\r") ? s.substring(0, s.length() - 1) : s;
      }
      sb.append((char) b);
    }
  }

  static byte[] readChunkedBody(InputStream raw) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    while (true) {
      String line = readAsciiLine(raw);
      if (line == null) break;
      String hex = line.trim();
      int semi = hex.indexOf(';'); if (semi >= 0) hex = hex.substring(0, semi).trim();
      int size;
      try { size = Integer.parseInt(hex, 16); } catch (Exception e) { break; }
      if (size == 0) { while (true) { String t = readAsciiLine(raw); if (t == null || t.isEmpty()) break; } break; }
      byte[] buf = new byte[size]; int got = 0;
      while (got < size) { int n = raw.read(buf, got, size - got); if (n <= 0) break; got += n; }
      out.write(buf, 0, got);
      readAsciiLine(raw);
    }
    return out.toByteArray();
  }

  /** 解析请求：按 headerLines 里有无 chunked 决定走哪条路（复刻桥接改前/改后）。 */
  static String[] parse(byte[] req, boolean supportChunked) throws IOException {
    InputStream raw = new ByteArrayInputStream(req);
    List<String> hs = new ArrayList<>();
    StringBuilder sb = new StringBuilder();
    while (true) {
      int b = raw.read();
      if (b < 0) break;
      if (b == '\n') {
        String s = sb.toString(); sb.setLength(0);
        if (s.endsWith("\r")) s = s.substring(0, s.length() - 1);
        if (s.isEmpty()) break;
        hs.add(s);
      } else sb.append((char) b);
    }
    int contentLength = 0; boolean chunked = false;
    for (String h : hs) {
      int i = h.indexOf(':'); if (i <= 0) continue;
      String k = h.substring(0, i).trim(), v = h.substring(i + 1).trim();
      if (k.equalsIgnoreCase("Content-Length")) contentLength = Integer.parseInt(v);
      else if (k.equalsIgnoreCase("Transfer-Encoding") && v.toLowerCase().contains("chunked")) chunked = true;
    }
    if (supportChunked && chunked) return new String[]{hs.get(0), new String(readChunkedBody(raw), StandardCharsets.UTF_8)};
    byte[] bb = new byte[contentLength]; int rd = 0;
    while (rd < contentLength) { int n = raw.read(bb, rd, contentLength - rd); if (n <= 0) break; rd += n; }
    return new String[]{hs.get(0), new String(bb, 0, rd, StandardCharsets.UTF_8)};
  }

  public static void main(String[] a) throws Exception {
    byte[] req = buildRequest();
    String[] oldR = parse(req, false);
    String[] newR = parse(req, true);
    System.out.println("请求体真实长度(UTF-8 字节): " + BODY.getBytes(StandardCharsets.UTF_8).length);
    System.out.println("【旧解析】正文长度 = " + oldR[1].getBytes(StandardCharsets.UTF_8).length
        + "  → jsonDecode 会抛: bad json: End of input at character 0 of   （复现真机 400）");
    System.out.println("【新解析】正文长度 = " + newR[1].getBytes(StandardCharsets.UTF_8).length);
    System.out.println("【新解析】正文与原文一致: " + newR[1].equals(BODY));
    System.out.println("【新旧判定】旧=" + (oldR[1].isEmpty() ? "空 ❌" : "非空")
        + "  新=" + (newR[1].equals(BODY) ? "完整 ✅" : "不对 ❌"));
  }
}
