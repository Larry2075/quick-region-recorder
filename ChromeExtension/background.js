const menuID = "select-region";
const hostName = "com.kongdexi.quick_region_recorder";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: menuID,
    title: "区域录屏",
    contexts: ["all"],
    documentUrlPatterns: ["http://*/*", "https://*/*"],
  });
});

chrome.contextMenus.onClicked.addListener(async ({ menuItemId }) => {
  if (menuItemId !== menuID) return;

  try {
    const response = await chrome.runtime.sendNativeMessage(hostName, { action: menuID });
    if (!response?.ok) throw new Error(response?.message || "快捷录屏未能打开。");
  } catch (error) {
    console.error("无法打开快捷录屏", error);
  }
});
