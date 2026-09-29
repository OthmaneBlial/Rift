const status = document.querySelector(".copy-status");
let statusTimeout;

for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copy);
    if (!source) return;

    try {
      await navigator.clipboard.writeText(source.innerText.trim());
      button.textContent = "Copied";
      status.textContent = "Install command copied to clipboard.";
    } catch {
      button.textContent = "Select code";
      status.textContent = "Clipboard access unavailable. Select the command to copy it.";
    }

    status.classList.add("is-visible");
    clearTimeout(statusTimeout);
    statusTimeout = setTimeout(() => {
      status.classList.remove("is-visible");
      button.textContent = "Copy";
    }, 2200);
  });
}
