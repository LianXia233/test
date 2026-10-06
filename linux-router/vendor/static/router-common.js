(() => {
  const operationPollTimeoutMs = 6 * 60 * 1000;
  // 长操作（apt 安装、热点起停）可能跑好几分钟。固定 1 秒轮询会在 6 分钟里
  // 打出 ~360 次请求，把 agent 的 Unix socket 和 CPU 都占住。这里改成
  // 1s 起步、每次 ×1.4、上限 5s 的退避：前 10 秒仍然跟手，之后降到 ~12 次/分钟。
  const pollIntervalStartMs = 1000;
  const pollIntervalMaxMs = 5000;
  const pollIntervalFactor = 1.4;

  // 只登记确实存在、且由通用表单触发的容器。热点页/网络页有自己的
  // updateXxxPage() 处理 fragments，不在这里重复映射，避免替换到错误容器。
  const fragmentTargets = {
    dependencies: "dependency-groups",
  };

  const applyFragments = (fragments) => {
    if (!fragments) return false;
    let applied = false;
    Object.entries(fragmentTargets).forEach(([key, elementId]) => {
      const html = fragments[key];
      if (html === undefined) return;
      const container = document.getElementById(elementId);
      if (!container) return;
      container.innerHTML = html;
      applied = true;
    });
    return applied;
  };

  window.routerHttp = {
    async postForm(url, formData, options = {}) {
      const response = await fetch(url, {
        method: "POST",
        body: formData,
        credentials: "same-origin",
        headers: { "X-Requested-With": "fetch" },
      });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      const result = await response.json();
      if (!result.pending || !result.operation_url) return result;

      const deadline = Date.now() + operationPollTimeoutMs;
      let interval = pollIntervalStartMs;
      while (true) {
        if (Date.now() >= deadline) {
          throw new Error("Operation polling timed out");
        }
        await new Promise((resolve) => window.setTimeout(resolve, interval));
        interval = Math.min(Math.round(interval * pollIntervalFactor), pollIntervalMaxMs);
        const operationResponse = await fetch(result.operation_url, {
          credentials: "same-origin",
          headers: { "X-Requested-With": "fetch" },
        });
        if (!operationResponse.ok) {
          throw new Error(`HTTP ${operationResponse.status}`);
        }
        const operation = await operationResponse.json();
        if (
          operation.pending
          && operation.progress_message
          && typeof options.onProgress === "function"
        ) {
          options.onProgress(operation.progress_message);
        }
        if (!operation.pending) return operation;
      }
    },
  };

  window.routerFeedback = {
    scoped(key) {
      return (message, type = "success", autoHideMs = 0) => {
        if (!window.routerToast) return;
        if (!message) {
          window.routerToast.clear(key);
          return;
        }
        window.routerToast.show(message, type, { key, autoHideMs });
      };
    },
  };

  document.querySelectorAll("[data-agent-operation-form]").forEach((form) => {
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const button = form.querySelector('button[type="submit"]');
      if (button) button.disabled = true;
      try {
        const result = await window.routerHttp.postForm(
          form.getAttribute("action"),
          new FormData(form),
        );
        if (window.routerToast) {
          window.routerToast.show(result.message || "操作已结束", result.ok ? "success" : "error", {
            key: "agent-operation",
            autoHideMs: result.ok ? 2000 : 0,
          });
        }
        // 后端返回了对应 fragment 就局部替换，只有拿不到 fragment 时才回退整页刷新
        if (!applyFragments(result.fragments)) {
          window.setTimeout(() => window.location.reload(), result.ok ? 700 : 1500);
        } else if (button) {
          button.disabled = false;
        }
      } catch {
        if (window.routerToast) {
          window.routerToast.show("系统操作失败", "error", { key: "agent-operation" });
        }
        if (button) button.disabled = false;
      }
    });
  });
})();
