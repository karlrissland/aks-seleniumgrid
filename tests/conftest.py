import os
import pytest
import logging
from datetime import datetime
from pathlib import Path
from selenium import webdriver
from selenium.webdriver.chrome.options import Options as ChromeOptions
from selenium.webdriver.firefox.options import Options as FirefoxOptions
from selenium.webdriver.edge.options import Options as EdgeOptions

logger = logging.getLogger(__name__)

def pytest_addoption(parser):
    """Add command-line flags to pytest for Grid URL and Browser selection."""
    parser.addoption(
        "--grid-url",
        action="store",
        default=os.environ.get("SELENIUM_GRID_URL", "http://localhost:4444/wd/hub"),
        help="URL of the remote Selenium Grid Hub (e.g. http://10.0.4.50:4444/wd/hub or http://localhost:4444/wd/hub)",
    )
    parser.addoption(
        "--browser-name",
        action="store",
        default="chrome",
        choices=["chrome", "firefox", "edge", "all"],
        help="Target browser: chrome, firefox, edge, or all",
    )

@pytest.fixture(scope="session")
def grid_url(request):
    """Returns the configured Selenium Grid Hub URL."""
    url = request.config.getoption("--grid-url")
    if not url.endswith("/wd/hub") and not url.endswith("/"):
        # Grid 4 supports both / and /wd/hub, standardize endpoint
        url = f"{url}/wd/hub"
    return url

def _get_options(browser_name: str):
    """Build browser-specific options for Remote WebDriver."""
    browser_lower = browser_name.lower()
    if browser_lower == "chrome":
        options = ChromeOptions()
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument("--disable-gpu")
        options.add_argument("--window-size=1920,1080")
        options.set_capability("se:recordVideo", "true")
        return options
    elif browser_lower == "firefox":
        options = FirefoxOptions()
        options.add_argument("--width=1920")
        options.add_argument("--height=1080")
        options.set_capability("se:recordVideo", "true")
        return options
    elif browser_lower in ["edge", "microsoftedge"]:
        options = EdgeOptions()
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument("--disable-gpu")
        options.add_argument("--window-size=1920,1080")
        options.set_capability("se:recordVideo", "true")
        return options
    else:
        raise ValueError(f"Unsupported browser: {browser_name}")

@pytest.fixture(params=["chrome", "firefox", "edge"])
def browser_type(request):
    """Parametrized fixture allowing tests to execute across all 3 browsers or a single chosen browser."""
    cli_browser = request.config.getoption("--browser-name")
    if cli_browser != "all" and request.param != cli_browser:
        pytest.skip(f"Skipping {request.param} as --browser-name is set to {cli_browser}")
    return request.param

@pytest.fixture
def driver(grid_url, browser_type, request):
    """Initializes and tears down a Selenium Remote WebDriver session."""
    logger.info(f"Connecting to Selenium Grid at '{grid_url}' with browser '{browser_type}'...")
    options = _get_options(browser_type)
    
    driver_instance = webdriver.Remote(
        command_executor=grid_url,
        options=options
    )
    driver_instance.implicitly_wait(10)
    driver_instance.set_page_load_timeout(30)
    
    yield driver_instance
    
    # Capture screenshot if test failed
    if hasattr(request.node, "rep_call") and request.node.rep_call.failed:
        results_dir = Path("test-results/screenshots")
        results_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        screenshot_path = results_dir / f"{request.node.name}_{browser_type}_{timestamp}.png"
        try:
            driver_instance.save_screenshot(str(screenshot_path))
            logger.warning(f"Saved failure screenshot to: {screenshot_path}")
            # Also attach the screenshot to the Allure report when available.
            try:
                import allure
                with open(screenshot_path, "rb") as img:
                    allure.attach(img.read(), name=f"{request.node.name}_{browser_type}", attachment_type=allure.attachment_type.PNG)
            except Exception:
                pass
        except Exception as e:
            logger.error(f"Failed to capture screenshot: {e}")
            
    logger.info(f"Closing browser session for {browser_type}")
    try:
        driver_instance.quit()
    except Exception as e:
        logger.warning(f"Error while quitting driver: {e}")

@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """Hook to capture test results for screenshot-on-failure mechanism."""
    outcome = yield
    rep = outcome.get_result()
    setattr(item, "rep_" + rep.when, rep)
