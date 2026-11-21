const pendingButton = document.querySelector("#download-pending");
const downloadLink = document.querySelector("#download-link");
const releaseStatus = document.querySelector("#release-status");

async function showRelease() {
  try {
    const response = await fetch("./release.json", { cache: "no-cache" });
    if (!response.ok) return;

    const release = await response.json();
    if (typeof release?.version !== "string" || typeof release.downloadUrl !== "string") return;
    if (!/^\d+\.\d+\.\d+$/.test(release.version)) return;

    const url = new URL(release.downloadUrl);
    const expected = `https://github.com/vladboyarinov1/branchline/releases/download/v${release.version}/Branchline.dmg`;
    if (url.href !== expected) return;

    downloadLink.href = url.href;
    pendingButton.hidden = true;
    downloadLink.hidden = false;
    releaseStatus.textContent = `Версия ${release.version}`;
    if (Number.isSafeInteger(release.size) && release.size > 0) {
      const size = new Intl.NumberFormat("ru", { maximumFractionDigits: 1 }).format(release.size / 1_000_000);
      releaseStatus.textContent += ` · ${size} МБ`;
    }
  } catch {
    // Keep the first-release state if the release metadata is temporarily unavailable.
  }
}

showRelease();
