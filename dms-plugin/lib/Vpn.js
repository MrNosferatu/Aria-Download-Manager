/* Which links the VPN's site list catches, as the manager decides it
   (aria_download_manager/vpn.py: site_of, on_list), so an add dialog can say
   "2 of 3 will use the VPN, based on the site list" before anything is added.

   Shared word for word by the extension (download dialog, manager page) and the
   DankBar plugin (dms-plugin/lib/Vpn.js; tests/test_vpn.py keeps the two
   identical and in step with the manager). Plain functions, no globals beyond
   them, so it loads as a classic <script> and as a QML JavaScript import. */

// A site as the list keeps it: a bare host, scheme, path, port, "*." and "www." off.
function vpnSiteOf(entry) {
  let text = String(entry || '').trim().toLowerCase();
  const scheme = text.indexOf('://');
  if (scheme >= 0) text = text.slice(scheme + 3);
  text = text.split('/')[0].split('?')[0].split('#')[0];
  if (text.indexOf('@') >= 0) text = text.slice(text.lastIndexOf('@') + 1);
  text = text.split(':')[0];
  for (const prefix of ['*.', 'www.']) {
    if (text.indexOf(prefix) === 0) text = text.slice(prefix.length);
  }
  return text.replace(/^\.+|\.+$/g, '');
}

// The link's host, lower case; '' for anything that is not a URL with one.
function vpnHostOf(url) {
  const match = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(String(url || '').trim());
  if (!match) return '';
  let host = match[1];
  if (host.indexOf('@') >= 0) host = host.slice(host.lastIndexOf('@') + 1);
  return host.split(':')[0].toLowerCase();
}

// The link's host is a listed site or one of its subdomains.
function vpnOnList(url, sites) {
  const host = vpnHostOf(url);
  if (!host) return false;
  return (sites || []).some((site) => site && (host === site || host.endsWith('.' + site)));
}

// How many of these links the list sends through the VPN.
function vpnCountOnList(urls, sites) {
  return (urls || []).filter((url) => vpnOnList(url, sites)).length;
}
