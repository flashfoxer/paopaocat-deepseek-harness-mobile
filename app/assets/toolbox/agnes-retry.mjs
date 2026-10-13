// 429 / 限流的统一处理 —— **生图与生视频共用这一份**。
//
// ## 为什么要单独一份
//
// 原来两个脚本遇到 429 都是**直接失败**（`fail(...)` 退出），一次限流 = 一次白干，
// 用户只能重新提交 —— 而重新提交会让平台队列更长，于是越试越堵。
// 而 429 绝大多数是**瞬时的**，退避几十秒就能过。
//
// 这份模块给两件事：
//   1. **退避重试**：优先听服务端的 `Retry-After`，没有就指数退避（默认 2s→4s→8s…封顶 60s）；
//   2. **多把 Key 轮换**（一把被限流就**立刻**换下一把；全都试过才退避）——
//      注意**只有提交阶段能换 Key**：任务归创建它的那把 Key 所有，查进度必须还用同一把，
//      否则会查不到（甚至报无权限）。这个约束写进了 [KeyRotator] 的用法说明。
//
// ## Key 从哪来
//
// 支持**多把**（都属于不同账号才有意义 —— 同一账号下多建 Key 共享同一份配额）：
//   * `AGNES_API_KEYS`：主用。用逗号 / 分号 / 空白 / 换行分隔都可以；
//   * `AGNES_API_KEY`：老变量，仍然认；只填了它 = 单 Key 行为，与以前完全一致。
//
// 只用 node 内置能力，不引任何依赖（本机只能跑内置模块）。

export const DEFAULT_ROUNDS = 3;
export const DEFAULT_BASE_MS = 2000;
export const DEFAULT_CAP_MS = 60000;

/**
 * **可重试的瞬时失败**（交给 [callWithRateLimitRetry] 决定退避/换 Key）。
 *
 * ⚠️ 抛这个之前先确认一件事：**这个操作重复一次安全吗？**
 *   · 出图：重复安全（最多多花一次额度）→ 429 与 5xx 都可以重试；
 *   · 出**视频的提交**：重复**不安全** —— 上一次可能已经建了任务（只是响应丢了），
 *     再提交就是第二个任务 + 再扣一次配额。所以视频提交只对 429 重试
 *     （429 是服务端明确拒收，说明没建任务），5xx / 超时一律不重试。
 *
 * 这条原则不是我自己想的：桌面端影视工具插件的代理里就是这么分的 ——
 * 生图 retries = 3、视频提交 retries = 0，注释写明
 * a duplicate would create a second task/quota hit。
 */
export class TransientError extends Error {
  constructor(message, retryAfterMs = null) {
    super(message);
    this.name = 'TransientError';
    this.retryAfterMs = retryAfterMs;
  }
}

/** 429（限流）专用 —— 语义上属于 [TransientError]，单独识别以便提示「限流」。 */
export class RateLimitedError extends TransientError {
  constructor(message, retryAfterMs = null) {
    super(message, retryAfterMs);
    this.name = 'RateLimitedError';
  }
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * 从环境里解析出**多把** API Key（保持顺序、去重、去掉空值）。
 *
 * 返回值永远是数组（可能为空，也可能只有一把）—— 调用方据此报"没配 Key"或
 * 决定要不要轮换。
 */
export function parseApiKeys(env = process.env) {
  const raw = [env.AGNES_API_KEYS || '', env.AGNES_API_KEY || ''].join('\n');
  const out = [];
  for (const piece of raw.split(/[\s,;]+/)) {
    const k = piece.trim();
    if (k && !out.includes(k)) out.push(k);
  }
  return out;
}

/**
 * 从响应头解析 `Retry-After` → 毫秒；没有或解析不出返回 `null`。
 *
 * 这个头有两种合法写法，**都要认**（不认的话就会用默认退避，可能比服务端要求的短）：
 *   * 秒数：`Retry-After: 30`
 *   * HTTP 日期：`Retry-After: Wed, 21 Oct 2026 07:28:00 GMT`
 */
export function retryAfterMs(headers) {
  if (!headers) return null;
  const raw = headers['retry-after'] ?? headers['Retry-After'];
  if (raw === undefined || raw === null) return null;
  const s = String(raw).trim();
  if (s === '') return null;
  if (/^\d+(\.\d+)?$/.test(s)) {
    const ms = Math.round(Number(s) * 1000);
    return Number.isFinite(ms) && ms >= 0 ? ms : null;
  }
  const at = Date.parse(s);
  if (Number.isNaN(at)) return null;
  const ms = at - Date.now();
  return ms > 0 ? ms : 0;
}

/** 指数退避：`base * 2^(attempt-1)`，封顶 `cap`。attempt 从 1 开始。 */
export function backoffMs(attempt, base = DEFAULT_BASE_MS, cap = DEFAULT_CAP_MS) {
  const n = Math.max(1, Math.floor(attempt));
  const raw = base * Math.pow(2, n - 1);
  return Math.min(cap, Math.round(raw));
}

/** 毫秒 → 「12 秒」/「1 分 20 秒」（给用户看的，不显示毫秒）。 */
export function humanDuration(ms) {
  const total = Math.max(0, Math.round(ms / 1000));
  if (total < 60) return `${total} 秒`;
  const m = Math.floor(total / 60);
  const s = total % 60;
  return s === 0 ? `${m} 分` : `${m} 分 ${s} 秒`;
}

/**
 * 多把 Key 的轮换器。
 *
 * ⚠️ **只在"提交任务"这条路径上用轮换**。任务一旦创建成功，它就属于那把 Key；
 * 查进度、取结果必须**继续用同一把**（`jobKey`），否则平台会认为你查的不是自己的任务。
 * 所以轮询阶段遇到 429 只能退避重试，**不能换 Key**。
 */
export class KeyRotator {
  constructor(keys) {
    const list = (keys || []).filter((k) => typeof k === 'string' && k.trim() !== '');
    if (list.length === 0) throw new Error('KeyRotator 需要至少一把 Key');
    this.keys = list;
    this.index = 0;
  }

  get count() {
    return this.keys.length;
  }

  /** 当前这把（第 `index + 1` 把）。 */
  get current() {
    return this.keys[this.index];
  }

  /** 第几把（从 1 开始，仅用于提示，**不要**把 Key 本身打出来）。 */
  get ordinal() {
    return this.index + 1;
  }

  /** 换下一把；只有一把时返回 false（调用方据此说明"没有备用 Key"）。 */
  rotate() {
    if (this.keys.length < 2) return false;
    this.index = (this.index + 1) % this.keys.length;
    return true;
  }

  /** 直接跳到第 [index] 把（0 基）。越界返回 false。 */
  rotateTo(index) {
    if (!Number.isInteger(index) || index < 0 || index >= this.keys.length) return false;
    if (index === this.index) return false;
    this.index = index;
    return true;
  }

  /** 从当前这把往后绕一圈，找第一把**没在 [tried] 里**的；找不到返回 -1。 */
  nextUntried(tried) {
    for (let step = 1; step <= this.keys.length; step += 1) {
      const idx = (this.index + step) % this.keys.length;
      if (!tried.has(idx)) return idx;
    }
    return -1;
  }
}

/**
 * 「被限流就退避重试；同一把 Key 连续被限流就换下一把」。
 *
 * [fn] 接收当前 Key，返回值即结果；遇到**可重试的瞬时失败**请抛 [TransientError]
 * （429 用 [RateLimitedError]，语义一样、只是提示会说「限流」）。
 * 其它异常**原样抛出**（比如 401/403 是 Key 的问题，退避重试没有意义）。
 *
 * ⚠️ 调用方**只对「重试安全」的操作抛 [TransientError]**：视频提交遇到 5xx/超时
 * 绝不能重试（上一次可能已经建了任务），详见 [TransientError] 的说明。
 *
 * 边界（都在测试里钉住）：
 *   * **一轮里每把 Key 只试一次**；全都试过才退避，最多 `rounds` 轮；
 *   * 总尝试次数 = `rounds * rotator.count`，无论如何都会终止；
 *   * 每次等待的秒数**优先用服务端给的 `Retry-After`**；
 *   * 只有一把 Key 时，行为 = 单纯退避重试（与多把时的单把等价）；
 *   * 全程不会把 Key 打印出来，只说"第几把"。
 */
export async function callWithRateLimitRetry(
  fn,
  {
    rotator,
    log = () => {},
    rounds = DEFAULT_ROUNDS,
    baseMs = DEFAULT_BASE_MS,
    capMs = DEFAULT_CAP_MS,
    sleepFn = sleep,
  } = {},
) {
  if (!rotator) throw new Error('callWithRateLimitRetry 需要 rotator');
  const totalBudget = rounds * rotator.count;
  let attempts = 0;
  let lastError = null;

  // 策略（为什么不是"同一把先重试几次"）：
  //
  // 限流/额度是**按账号**算的。所以当第 1 把被限流时，**立刻**拿第 2 把去试，
  // 成功的概率远高于"拿被限流的第 1 把再撞几次" —— 后者只是白等。
  // 只有**本轮所有 Key 都被限流**，才退避等待、开始下一轮（那时等才有意义）。
  for (let round = 1; round <= rounds; round += 1) {
    const tried = new Set();
    for (;;) {
      tried.add(rotator.index);
      attempts += 1;
      try {
        return await fn(rotator.current);
      } catch (e) {
        if (!(e instanceof TransientError)) throw e; // 401/403 这类退避没用，原样抛
        lastError = e;

        const next = rotator.nextUntried(tried);
        if (next >= 0) {
          const before = rotator.ordinal;
          rotator.rotateTo(next);
          log(
            `第 ${before} 把 Key 被限流（HTTP 429），直接换第 ${rotator.ordinal} 把` +
              `（共 ${rotator.count} 把）再试…`,
          );
          continue; // 换 Key 后**不等**：另一个账号通常没被限流
        }

        // 本轮所有 Key 都被限流了。
        if (round >= rounds || attempts >= totalBudget) {
          // 没机会再来一轮 → 跳出，走下面的"如实报错"
          round = rounds + 1;
          break;
        }
        const waitMs = e.retryAfterMs ?? backoffMs(round, baseMs, capMs);
        log(
          `${rotator.count} 把 Key 本轮都被限流，等 ${humanDuration(waitMs)} 后开始第 ` +
            `${round + 1}/${rounds} 轮（任务仍在平台侧，不会重复提交）…`,
        );
        await sleepFn(waitMs);
        break; // 下一轮
      }
    }
  }

  // 全都试过了 —— 如实说清"试了几把、几次"，并把平台原话带出来。
  const suffix = lastError?.message ? `最后一次平台回复：${lastError.message}` : '';
  throw new Error(
    `持续被限流：试了 ${rotator.count} 把 Key、共 ${attempts} 次仍未通过。` +
      `请稍后重试；如果一直这样，可能是账号额度用完了，或短时间内提交的任务太多。` +
      (suffix ? `\n       ${suffix}` : ''),
  );
}
