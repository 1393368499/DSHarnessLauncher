from pathlib import Path
from playwright.sync_api import sync_playwright

root = Path(__file__).resolve().parent
errors = []

with sync_playwright() as playwright:
    browser = playwright.chromium.launch(
        headless=True,
        executable_path=r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    )
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
    page.goto("http://127.0.0.1:4173")
    page.wait_for_load_state("networkidle")

    assert page.title() == "DSHarness"
    assert page.get_by_text("完整 Harness，原生桌面工作台。").is_visible()
    assert page.get_by_role("button", name="↻ 更新").is_visible()
    assert page.get_by_role("button", name="⌁ 修复").is_visible()

    page.get_by_role("button", name="鲸").click()
    assert page.locator("html").get_attribute("data-theme") == "whale"
    assert page.locator(".maid").count() == 2
    page.locator(".maid-left").wait_for(state="visible")
    page.locator(".maid-right").wait_for(state="visible")
    page.screenshot(path=str(root / "test-artifacts" / "dsharness-whale.png"), full_page=True)

    page.get_by_role("button", name="能力中心").click()
    assert page.get_by_text("完整能力安装").is_visible()
    assert page.get_by_role("button", name="安装完整 Harness 组件").is_visible()
    assert page.get_by_role("button", name="检查并更新核心").is_visible()

    page.get_by_role("button", name="插件工坊").click()
    page.locator("#task").fill("生成带引用的 Markdown 周报")
    page.evaluate("document.querySelector('#forge').onclick()")
    page.wait_for_timeout(1000)
    forge_result = page.locator("#forge-result").inner_text()
    assert "已生成" in forge_result

    page.get_by_role("button", name="更新与设置").click()
    assert page.get_by_text("版本 4.0.1 · 原生轻量壳").is_visible()
    assert page.get_by_role("button", name="修复完整核心").is_visible()
    page.screenshot(path=str(root / "test-artifacts" / "dsharness-ui.png"), full_page=True)
    browser.close()

assert not errors, f"browser console errors: {errors}"
print("DSHarness UI regression passed")
