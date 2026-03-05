const schemas = {
  organizations: {
    label: '机构管理',
    endpoint: '/api/organizations',
    fields: [{ key: 'name', label: '机构名称', type: 'text', required: true }],
  },
  users: {
    label: '用户与角色',
    endpoint: '/api/users',
    fields: [
      { key: 'org_id', label: '机构ID', type: 'number', required: true },
      { key: 'name', label: '姓名', type: 'text', required: true },
      { key: 'role', label: '角色', type: 'select', options: ['super_admin','org_admin','teacher','student_parent','finance'], required: true },
    ],
  },
  courses: {
    label: '课程管理',
    endpoint: '/api/courses',
    fields: [
      { key: 'org_id', label: '机构ID', type: 'number', required: true },
      { key: 'title', label: '课程名', type: 'text', required: true },
      { key: 'teacher_id', label: '教师用户ID', type: 'number' },
    ],
  },
  enrollments: {
    label: '选课管理',
    endpoint: '/api/enrollments',
    fields: [
      { key: 'course_id', label: '课程ID', type: 'number', required: true },
      { key: 'student_id', label: '学员/家长ID', type: 'number', required: true },
      { key: 'status', label: '状态', type: 'select', options: ['active','dropped','transferred'] },
    ],
  },
  homework: {
    label: '作业管理',
    endpoint: '/api/homework',
    fields: [
      { key: 'course_id', label: '课程ID', type: 'number', required: true },
      { key: 'title', label: '作业标题', type: 'text', required: true },
      { key: 'description', label: '作业说明', type: 'text' },
    ],
  },
  grades: {
    label: '成绩管理',
    endpoint: '/api/grades',
    fields: [
      { key: 'enrollment_id', label: '选课ID', type: 'number', required: true },
      { key: 'score', label: '分数', type: 'number', required: true },
      { key: 'comment', label: '评语', type: 'text' },
    ],
  },
  payments: {
    label: '收费管理',
    endpoint: '/api/payments',
    fields: [
      { key: 'org_id', label: '机构ID', type: 'number', required: true },
      { key: 'student_id', label: '学员/家长ID', type: 'number', required: true },
      { key: 'amount', label: '金额', type: 'number', required: true },
      { key: 'status', label: '状态', type: 'select', options: ['paid','refund'], required: true },
    ],
  },
};

let current = 'organizations';

function el(id) { return document.getElementById(id); }

async function request(url, opts = {}) {
  const res = await fetch(url, { headers: { 'Content-Type': 'application/json' }, ...opts });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || '请求失败');
  return data;
}

function renderTabs() {
  el('tabs').innerHTML = Object.keys(schemas).map(key => `
    <div class="tab ${key === current ? 'active' : ''}" data-key="${key}">${schemas[key].label}</div>
  `).join('');
  document.querySelectorAll('.tab').forEach(tab => {
    tab.onclick = () => {
      current = tab.dataset.key;
      renderAll();
    };
  });
}

function renderForm() {
  const schema = schemas[current];
  el('page-title').textContent = schema.label;
  el('form-title').textContent = `新增${schema.label}`;
  el('list-title').textContent = `${schema.label}列表`;
  el('entity-form').className = 'row';
  el('entity-form').innerHTML = schema.fields.map(f => {
    if (f.type === 'select') {
      return `<label>${f.label}<select name="${f.key}">${f.options.map(o => `<option value="${o}">${o}</option>`).join('')}</select></label>`;
    }
    return `<label>${f.label}<input name="${f.key}" type="${f.type}" ${f.required ? 'required' : ''}></label>`;
  }).join('') + '<button class="btn-primary" type="submit">提交</button>';

  el('entity-form').onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    const payload = {};
    schema.fields.forEach(f => {
      const value = fd.get(f.key);
      if (value === '' || value === null) return;
      payload[f.key] = f.type === 'number' ? Number(value) : value;
    });
    try {
      await request(schema.endpoint, { method: 'POST', body: JSON.stringify(payload) });
      e.target.reset();
      await loadTable();
      await loadStats();
    } catch (err) {
      alert(err.message);
    }
  };
}

function toTable(data) {
  if (!data.length) return '<div style="padding:12px;color:#6b7280;">暂无数据</div>';
  const cols = Object.keys(data[0]);
  const thead = `<tr>${cols.map(c => `<th>${c}</th>`).join('')}</tr>`;
  const tbody = data.map(row => `<tr>${cols.map(c => `<td>${row[c] ?? ''}</td>`).join('')}</tr>`).join('');
  return `<table><thead>${thead}</thead><tbody>${tbody}</tbody></table>`;
}

async function loadTable() {
  const data = await request(schemas[current].endpoint);
  el('table-wrap').innerHTML = toTable(data);
}

async function loadStats() {
  const entries = Object.entries(schemas);
  const nums = await Promise.all(entries.map(([k, v]) => request(v.endpoint).then(arr => [k, arr.length])));
  el('stats').innerHTML = nums.map(([k, n]) => `<div class="stat"><span>${schemas[k].label}</span><strong>${n}</strong></div>`).join('');
}

async function initHealth() {
  try {
    const health = await request('/health');
    const h = el('health');
    h.textContent = `${health.status} (${health.db})`;
    h.classList.add('ok');
  } catch {
    el('health').textContent = '服务不可用';
  }
}

function initReport() {
  el('report-form').innerHTML = `
    <label>机构ID<input name="org_id" type="number" required></label>
    <button class="btn-primary" type="submit">查询营收</button>
  `;
  el('report-form').onsubmit = async (e) => {
    e.preventDefault();
    const orgId = new FormData(e.target).get('org_id');
    try {
      const result = await request(`/api/report/revenue?org_id=${orgId}`);
      el('report-output').textContent = JSON.stringify(result, null, 2);
    } catch (err) {
      el('report-output').textContent = err.message;
    }
  };
}

async function renderAll() {
  renderTabs();
  renderForm();
  await loadTable();
}

el('refresh-btn').onclick = async () => { await loadTable(); await loadStats(); };

(async function boot() {
  await initHealth();
  await loadStats();
  initReport();
  await renderAll();
})();
