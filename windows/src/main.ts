import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import './styles.css';

type Nullable<T> = T | null;

interface QuotaService {
  id: string;
  appName: string;
  name: string;
  quotaLabel: string;
  plan: string;
  symbol: string;
  current: number;
  max: number;
  resetAt: string;
  accentHex: string;
  resetWindow: Nullable<string>;
  disabledReason: Nullable<string>;
  resetNote: Nullable<string>;
}

interface DashboardState {
  services: QuotaService[];
  refreshIssues: string[];
  lastRefreshAt: Nullable<string>;
  isRefreshing: boolean;
  liveServiceNames: string[];
  refreshStatusText: string;
}

interface QuotaGroup {
  appName: string;
  services: QuotaService[];
  highestUsage: number;
}

let state: DashboardState = {
  services: [],
  refreshIssues: [],
  lastRefreshAt: null,
  isRefreshing: false,
  liveServiceNames: [],
  refreshStatusText: '尚未同步',
};

const app = document.querySelector<HTMLDivElement>('#app');
if (!app) {
  throw new Error('App root missing');
}

const serviceRank = (service: QuotaService) => {
  switch (service.resetWindow) {
    case 'month':
      return 4;
    case 'week':
    case 'weekly':
      return 3;
    case '5d':
      return 2;
    case '5h':
      return 1;
    default:
      return 0;
  }
};

const percentage = (service: QuotaService) => (service.max <= 0 ? 0 : Math.max(0, Math.min(1, service.current / service.max)));

const percentLabel = (service: QuotaService) => (service.max <= 0 ? 'N/A' : `${Math.round(percentage(service) * 100)}%`);

const formatRelativeReset = (isoValue: string) => {
  const resetAt = new Date(isoValue);
  const diffMs = resetAt.getTime() - Date.now();
  if (Number.isNaN(resetAt.getTime())) return 'Reset time unavailable';
  if (diffMs <= 0) return '已重置';
  const totalMinutes = Math.floor(diffMs / 60000);
  const days = Math.floor(totalMinutes / (60 * 24));
  const hours = Math.floor((totalMinutes % (60 * 24)) / 60);
  const minutes = totalMinutes % 60;
  if (days > 0) return `${days}d ${hours}h`; 
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
};

const groupServices = (services: QuotaService[]): QuotaGroup[] => {
  const groups = new Map<string, QuotaService[]>();
  for (const service of services) {
    const existing = groups.get(service.appName) ?? [];
    existing.push(service);
    groups.set(service.appName, existing);
  }
  return [...groups.entries()]
    .map(([appName, grouped]) => ({
      appName,
      services: grouped.sort((left, right) => serviceRank(right) - serviceRank(left)),
      highestUsage: Math.max(...grouped.map((service) => percentage(service))),
    }))
    .sort((left, right) => right.highestUsage - left.highestUsage || left.appName.localeCompare(right.appName));
};

const ringMarkup = (service: QuotaService, radius: number) => {
  const circumference = 2 * Math.PI * radius;
  const progress = circumference * (1 - percentage(service));
  return `
    <circle class="gauge-track" cx="72" cy="72" r="${radius}"></circle>
    <circle class="gauge-progress" cx="72" cy="72" r="${radius}" stroke="${service.accentHex}" stroke-dasharray="${circumference}" stroke-dashoffset="${progress}"></circle>
  `;
};

const modalMarkup = (service: Nullable<QuotaService>) => {
  if (!service) return '';
  const resetAt = service.resetAt ? new Date(service.resetAt).toISOString().slice(0, 16) : new Date().toISOString().slice(0, 16);
  return `
    <div class="modal-backdrop" data-close-modal>
      <div class="modal" role="dialog" aria-modal="true" aria-label="Edit service">
        <form id="service-form" class="service-form">
          <input type="hidden" name="id" value="${service.id}" />
          <label><span>App</span><input name="appName" value="${service.appName}" required /></label>
          <label><span>Name</span><input name="name" value="${service.name}" required /></label>
          <label><span>Quota label</span><input name="quotaLabel" value="${service.quotaLabel}" required /></label>
          <label><span>Plan</span><input name="plan" value="${service.plan}" required /></label>
          <label><span>Symbol</span><input name="symbol" value="${service.symbol}" required maxlength="2" /></label>
          <label><span>Current</span><input name="current" type="number" value="${service.current}" required /></label>
          <label><span>Max</span><input name="max" type="number" value="${service.max}" required /></label>
          <label><span>Reset at</span><input name="resetAt" type="datetime-local" value="${resetAt}" required /></label>
          <label><span>Accent</span><input name="accentHex" value="${service.accentHex}" required /></label>
          <label><span>Window</span><input name="resetWindow" value="${service.resetWindow ?? ''}" /></label>
          <label><span>Disabled reason</span><input name="disabledReason" value="${service.disabledReason ?? ''}" /></label>
          <label><span>Reset note</span><input name="resetNote" value="${service.resetNote ?? ''}" /></label>
          <div class="modal-actions">
            <button type="button" data-close-modal>Cancel</button>
            <button type="submit">Save</button>
          </div>
        </form>
      </div>
    </div>
  `;
};

let editingService: Nullable<QuotaService> = null;

const render = () => {
  const groups = groupServices(state.services);
  app.innerHTML = `
    <main class="shell">
      <header class="toolbar">
        <div>
          <h1>AgentQuota</h1>
          <p>${state.refreshStatusText}</p>
        </div>
        <div class="toolbar-actions">
          <button data-action="refresh" ${state.isRefreshing ? 'disabled' : ''}>Refresh</button>
          <button data-action="add">Add</button>
          <button data-action="reset">Reset</button>
        </div>
      </header>
      ${state.refreshIssues.length ? `<section class="issues">${state.refreshIssues.map((issue) => `<p>${issue}</p>`).join('')}</section>` : ''}
      <section class="cards">
        ${groups
          .map((group) => {
            const radii = [54, 42, 30, 18];
            const lead = group.services[0];
            return `
              <article class="card">
                <div class="card-header">
                  <div>
                    <p class="eyebrow">${lead.plan}</p>
                    <h2>${group.appName}</h2>
                  </div>
                  <div class="symbol" style="background:${lead.accentHex}">${lead.symbol}</div>
                </div>
                <div class="card-body">
                  <svg class="gauge" viewBox="0 0 144 144" aria-hidden="true">
                    ${group.services.map((service, index) => ringMarkup(service, radii[index] ?? 12)).join('')}
                  </svg>
                  <div class="service-list">
                    ${group.services
                      .map(
                        (service) => `
                          <div class="service-row">
                            <div>
                              <strong>${service.quotaLabel}</strong>
                              <p>${percentLabel(service)} · reset in ${formatRelativeReset(service.resetAt)}</p>
                              ${service.disabledReason ? `<p class="meta warning">${service.disabledReason}</p>` : ''}
                              ${service.resetNote ? `<p class="meta">${service.resetNote}</p>` : ''}
                            </div>
                            <div class="service-actions">
                              <span class="usage">${service.current}/${service.max > 0 ? service.max : 'N/A'}</span>
                              <button data-edit="${service.id}">Edit</button>
                              <button data-delete="${service.id}">Delete</button>
                            </div>
                          </div>
                        `,
                      )
                      .join('')}
                  </div>
                </div>
              </article>
            `;
          })
          .join('')}
      </section>
      ${modalMarkup(editingService)}
    </main>
  `;

  app.querySelectorAll<HTMLButtonElement>('[data-action="refresh"]').forEach((button) => {
    button.onclick = async () => {
      state = await invoke<DashboardState>('refresh_live_data');
      render();
    };
  });

  app.querySelectorAll<HTMLButtonElement>('[data-action="reset"]').forEach((button) => {
    button.onclick = async () => {
      state = await invoke<DashboardState>('reset_demo_data');
      render();
    };
  });

  app.querySelectorAll<HTMLButtonElement>('[data-action="add"]').forEach((button) => {
    button.onclick = () => {
      editingService = {
        id: crypto.randomUUID(),
        appName: 'Custom',
        name: `Custom ${state.services.length + 1}`,
        quotaLabel: 'Manual quota',
        plan: 'Manual',
        symbol: 'M',
        current: 0,
        max: 100,
        resetAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
        accentHex: '#7C3AED',
        resetWindow: 'week',
        disabledReason: null,
        resetNote: null,
      };
      render();
    };
  });

  app.querySelectorAll<HTMLButtonElement>('[data-edit]').forEach((button) => {
    button.onclick = () => {
      editingService = state.services.find((service) => service.id === button.dataset.edit) ?? null;
      render();
    };
  });

  app.querySelectorAll<HTMLButtonElement>('[data-delete]').forEach((button) => {
    button.onclick = async () => {
      const id = button.dataset.delete;
      if (!id) return;
      state = await invoke<DashboardState>('delete_service', { id });
      render();
    };
  });

  app.querySelectorAll<HTMLElement>('[data-close-modal]').forEach((element) => {
    element.onclick = (event) => {
      if (event.target !== element && !(element instanceof HTMLButtonElement)) return;
      editingService = null;
      render();
    };
  });

  const form = app.querySelector<HTMLFormElement>('#service-form');
  if (form) {
    form.onsubmit = async (event) => {
      event.preventDefault();
      const formData = new FormData(form);
      const service: QuotaService = {
        id: String(formData.get('id')),
        appName: String(formData.get('appName')),
        name: String(formData.get('name')),
        quotaLabel: String(formData.get('quotaLabel')),
        plan: String(formData.get('plan')),
        symbol: String(formData.get('symbol')),
        current: Number(formData.get('current')),
        max: Number(formData.get('max')),
        resetAt: new Date(String(formData.get('resetAt'))).toISOString(),
        accentHex: String(formData.get('accentHex')),
        resetWindow: String(formData.get('resetWindow') || '') || null,
        disabledReason: String(formData.get('disabledReason') || '') || null,
        resetNote: String(formData.get('resetNote') || '') || null,
      };
      state = await invoke<DashboardState>('upsert_service', { service });
      editingService = null;
      render();
    };
  }
};

const bootstrap = async () => {
  state = await invoke<DashboardState>('get_services');
  render();
  setInterval(() => render(), 30_000);
  await listen<DashboardState>('quota-state', (event) => {
    state = event.payload;
    render();
  });
};

void bootstrap();
