import java.util.*;

/** 证明 alternating() 能把 DSH 那种「不交替」的消息列表变成 LiteRT-LM 能接受的形状。 */
public class AlternatingTest {
  /** 与 LiteRtLmBridge.kt 的 alternating() 一一对应。 */
  static List<String[]> alternating(List<String[]> items) {
    List<String[]> out = new ArrayList<>();
    for (String[] it : items) {
      String role = it[0], text = it[1];
      if (text.trim().isEmpty()) continue;
      if (out.isEmpty() && !role.equals("user")) continue;
      String[] last = out.isEmpty() ? null : out.get(out.size() - 1);
      if (last != null && last[0].equals(role)) {
        out.set(out.size() - 1, new String[]{role, last[1] + "\n\n" + text});
      } else out.add(new String[]{role, text});
    }
    return out;
  }
  /** 交替性校验：必须以 user 开头，且相邻角色不同。 */
  static boolean alternates(List<String[]> l) {
    if (l.isEmpty()) return true;
    if (!l.get(0)[0].equals("user")) return false;
    for (int i = 1; i < l.size(); i++) if (l.get(i)[0].equals(l.get(i - 1)[0])) return false;
    return true;
  }
  static List<String[]> L(String... rs) { List<String[]> o = new ArrayList<>(); for (String r : rs) o.add(new String[]{r, "内容-" + r}); return o; }
  static void t(String name, List<String[]> in) {
    List<String[]> o = alternating(in);
    StringBuilder sb = new StringBuilder();
    for (String[] x : o) sb.append(x[0]).append("→");
    System.out.printf("  %-34s %s  交替合法=%s%n", name, sb.length() == 0 ? "(空)" : sb.toString(), alternates(o) ? "✅" : "❌");
  }
  public static void main(String[] a) {
    System.out.println("输入形状 → 合法化后的角色序列：");
    t("DSH 真实形状 [sys,sys,user]", L("user"));                 // sys 已折进 systemInstruction
    t("[user, user]（快照+真话，实测报错）", L("user", "user"));
    t("[user, user, user]", L("user", "user", "user"));
    t("[model, user]（历史以助手开场）", L("model", "user"));
    t("[user, model, user, user]", L("user", "model", "user", "user"));
    t("[user, model, user, model, user]（正常多轮）", L("user", "model", "user", "model", "user"));
  }
}
