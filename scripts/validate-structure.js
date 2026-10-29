/*
 * Статическая проверка структуры Ansible-проекта без установленного Ansible:
 *  1) полнота каталогов ролей;
 *  2) существование файлов у include_tasks / include_vars;
 *  3) существование шаблонов у template: src;
 *  4) соответствие имён notify: объявлениям в handlers;
 *  5) все используемые переменные объявлены (defaults/vars/group_vars/host_vars)
 *     или относятся к фактам/встроенным;
 *  6) FQCN модулей имеют префикс коллекции.
 */
const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const root = process.argv[2];
const problems = [];
const note = (m) => problems.push(m);

const readYaml = (p) => yaml.load(fs.readFileSync(p, 'utf8')) ?? null;
const walk = (dir, re, acc = []) => {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['node_modules', '.git', 'collections'].includes(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, re, acc);
    else if (re.test(e.name)) acc.push(p);
  }
  return acc;
};

/* ---------- собираем объявленные переменные ---------- */
const declared = new Set([
  //facts и служебные
  'inventory_hostname', 'ansible_host', 'ansible_fqdn', 'ansible_os_family',
  'ansible_distribution', 'ansible_distribution_release', 'ansible_python_interpreter',
  'ansible_user', 'ansible_port', 'ansible_become', 'ansible_ssh_private_key_file',
  'item', 'scope', 'playbook_dir', 'groups', 'hostvars', 'lookup',
]);
const collectKeys = (obj) => {
  if (!obj || typeof obj !== 'object') return;
  for (const [k, v] of Object.entries(obj)) {
    declared.add(k);
    if (k === 'vars' || k === 'block' || k === 'rescue') collectKeys(v);
    if (Array.isArray(v)) v.forEach(collectKeys);
  }
};
for (const f of walk(root, /^.*\.ya?ml$/)) {
  const rel = f.replace(/\\/g, '/');
  if (/(defaults|vars|group_vars|host_vars)\/.*\.ya?ml$/.test(rel)) {
    try { collectKeys(readYaml(f)); } catch (e) { note('Не читается ' + rel + ': ' + e.message); }
  }
}

/* ---------- обход ролей ---------- */
const rolesDir = path.join(root, 'roles');
const roleVarsFromTasks = new Set();
const roleHandlers = {};

for (const role of fs.readdirSync(rolesDir)) {
  const rd = path.join(rolesDir, role);
  for (const sub of ['tasks', 'handlers', 'defaults', 'meta']) {
    if (!fs.existsSync(path.join(rd, sub, 'main.yml'))) note(`[${role}] отсутствует ${sub}/main.yml`);
  }
  const handlersFile = path.join(rd, 'handlers', 'main.yml');
  roleHandlers[role] = new Set();
  if (fs.existsSync(handlersFile)) {
    for (const h of readYaml(handlersFile) ?? []) if (h.name) roleHandlers[role].add(h.name);
  }

  for (const tf of walk(path.join(rd, 'tasks'), /\.yml$/)) {
    const tasks = readYaml(tf) ?? [];
    const visit = (t) => {
      if (!t || typeof t !== 'object') return;
      if (t.name) { /* ok */ }
      if (t.include_tasks) {
        const p = path.join(rd, 'tasks', t.include_tasks);
        if (!fs.existsSync(p)) note(`[${role}] include_tasks -> нет файла ${t.include_tasks}`);
      }
      if (t.include_vars) {
        const p = path.join(rd, 'vars', t.include_vars);
        if (!fs.existsSync(p)) note(`[${role}] include_vars -> нет файла vars/${t.include_vars}`);
      }
      if (t.notify) {
        const list = Array.isArray(t.notify) ? t.notify : [t.notify];
        for (const n of list) if (!roleHandlers[role].has(n)) note(`[${role}] notify "${n}" не объявлен в handlers`);
      }
      const tpl = t.template || {};
      if (tpl.src) {
        const p = path.join(rd, 'templates', tpl.src);
        if (!fs.existsSync(p)) note(`[${role}] template src=${tpl.src} -> файл отсутствует`);
      }
      for (const k of ['block', 'rescue', 'always']) if (Array.isArray(t[k])) t[k].forEach(visit);
      if (Array.isArray(t.tasks)) t.tasks.forEach(visit);
    };
    (Array.isArray(tasks) ? tasks : []).forEach(visit);

    //собираем set_fact / register имена как объявленные переменные
    const scan = (t) => {
      if (!t || typeof t !== 'object') return;
      if (t.register) declared.add(t.register);
      if (t.set_fact) Object.keys(t.set_fact).forEach((k) => declared.add(k));
      if (t.vars) Object.keys(t.vars).forEach((k) => declared.add(k));
      for (const k of ['block', 'rescue', 'always', 'tasks']) if (Array.isArray(t[k])) t[k].forEach(scan);
    };
    (Array.isArray(tasks) ? tasks : []).forEach(scan);
  }
}

/* ---------- поиск использованных {{ var }} ---------- */
// Переменные, объявленные в задачах (register/set_fact/loop-переменные) и в
// Jinja-циклах шаблонов, собираются до проверки использованных имён.
const collectFromTasksDeep = (file) => {
  let data;
  try { data = readYaml(file); } catch { return; }
  const scan = (t) => {
    if (!t || typeof t !== 'object') return;
    if (t.register) declared.add(t.register);
    // set_fact доступен и как set_fact, и как ansible.builtin.set_fact
    for (const k of Object.keys(t)) {
      if (k === 'set_fact' || k.endsWith('.set_fact')) {
        Object.keys(t[k] ?? {}).forEach((name) => declared.add(name));
      }
    }
    if (t.vars) Object.keys(t.vars).forEach((k) => declared.add(k));
    if (t.loop_control && t.loop_control.loop_var) declared.add(t.loop_control.loop_var);
    for (const k of ['block', 'rescue', 'always', 'tasks', 'handlers', 'post_tasks']) {
      if (Array.isArray(t[k])) t[k].forEach(scan);
    }
    if (Array.isArray(t.roles)) t.roles.forEach(scan);
  };
  if (Array.isArray(data)) data.forEach(scan);
};
for (const f of walk(root, /\.yml$/)) {
  const rel = f.replace(/\\/g, '/');
  if (/(tasks|handlers|playbooks)\/.*\.yml$/.test(rel)) collectFromTasksDeep(f);
}

// Переменные Jinja-циклов: {% for a, b in ... %} / {% set x = %} / {% block %}
for (const f of walk(root, /\.j2$/)) {
  const txt = fs.readFileSync(f, 'utf8');
  for (const m of txt.matchAll(/\{%-?\s*for\s+([a-zA-Z0-9_,\s]+?)\s+in\b/g)) {
    m[1].split(',').forEach((v) => declared.add(v.trim()));
  }
  for (const m of txt.matchAll(/\{%-?\s*(?:set|if)\s+\(?\s*([a-zA-Z_][a-zA-Z0-9_]*)/g)) declared.add(m[1]);
}

const knownPrefixes = ['ansible_', 'omit', 'true', 'false', 'none', 'item', 'scope', 'playbook_dir', 'groups', 'hostvars', 'query', 'lookup', 'now', 'range', 'dict', 'item.'];
const usedIn = {};
for (const f of walk(root, /\.(yml|j2)$/)) {
  const rel = f.replace(/\\/g, '/');
  if (/(defaults|vars|group_vars|host_vars)\/.*\.ya?ml$/.test(rel)) continue;
  const txt = fs.readFileSync(f, 'utf8');
  for (const m of txt.matchAll(/\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)/g)) {
    const v = m[1];
    if (declared.has(v) || knownPrefixes.some((p) => v.startsWith(p))) continue;
    (usedIn[v] = usedIn[v] || new Set()).add(rel);
  }
}
for (const [v, files] of Object.entries(usedIn)) {
  note(`Переменная "${v}" используется, но нигде не объявлена: ${[...files].slice(0, 3).join(', ')}`);
}

/* ---------- FQCN модулей ---------- */
for (const f of walk(root, /\.yml$/)) {
  if (!/(tasks|handlers)\/.*\.yml$/.test(f.replace(/\\/g, '/'))) continue;
  for (const t of readYaml(f) ?? []) {
    if (!t || typeof t !== 'object') continue;
    for (const key of Object.keys(t)) {
      if (/^[a-z_]+$/.test(key) && !['name', 'when', 'loop', 'register', 'notify', 'tags', 'vars', 'become', 'become_user', 'become_method', 'no_log', 'changed_when', 'failed_when', 'args', 'block', 'rescue', 'always', 'ignore_errors', 'retries', 'delay', 'until', 'check_mode', 'any_errors_fatal', 'loop_control', 'run_once', 'throttle', 'delegate_to', 'environment', 'when_changed'].includes(key)) {
        note(`Возможно не-FQCN модуль "${key}" в ${f.replace(/\\/g, '/')}`);
      }
    }
  }
}

console.log('Объявлено переменных: ' + declared.size);
if (problems.length === 0) console.log('Проблем не найдено.');
else { console.log('\nНайдено замечаний: ' + problems.length); problems.forEach((p) => console.log(' - ' + p)); }
process.exit(problems.length ? 1 : 0);
