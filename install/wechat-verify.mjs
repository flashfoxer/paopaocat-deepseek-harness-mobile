// 验证微信公众号凭证是否可用（只取 access_token，不做任何写操作）。
// 用 node 原生 fetch：本机 curl 有 schannel 证书问题、Invoke-WebRequest 会被断，
// 而 node 的 undici 在这台机器上实测可用（见 HANDOFF 的容器修复技巧）。
//
// 用法: node wechat-verify.mjs <appid> <secret>
// 输出: 只打印 errcode/errmsg 与 token 的长度（**不打印 token 本身**）。
const [, , appid, secret] = process.argv;
if (!appid || !secret) {
  console.error('usage: node wechat-verify.mjs <appid> <secret>');
  process.exit(2);
}

const url = 'https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential'
  + '&appid=' + encodeURIComponent(appid)
  + '&secret=' + encodeURIComponent(secret);

try {
  const res = await fetch(url, { method: 'GET' });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = { raw: text }; }

  console.log('HTTP', res.status);
  if (data.access_token) {
    console.log('OK: 凭证有效，access_token 长度 =', String(data.access_token).length,
      '，有效期约', data.expires_in, '秒');
    // 顺手看一下这个号是不是测试号 / 有什么限制（只读接口）
    const dbg = await fetch('https://api.weixin.qq.com/cgi-bin/openapi/quota/get?access_token=' + data.access_token,
      { method: 'POST', body: JSON.stringify({ cgi_path: '/cgi-bin/token' }) }).then(r => r.json()).catch(e => ({ err: String(e) }));
    console.log('配额接口回包:', JSON.stringify(dbg).slice(0, 200));
  } else {
    console.log('FAIL errcode =', data.errcode, 'errmsg =', data.errmsg);
    if (data.errcode === 40164) {
      console.log('提示: 40164 = 调用来源 IP 不在白名单。需要到公众号后台把本机公网 IP 加进 IP 白名单。');
    }
    if (String(data.errmsg || '').includes('invalid ip')) {
      console.log('回包里带了具体 IP，去后台加白名单即可。');
    }
  }
  console.log('原始回包(截断):', text.slice(0, 300));
} catch (e) {
  console.log('请求异常:', e && e.message ? e.message : String(e));
  process.exit(1);
}
