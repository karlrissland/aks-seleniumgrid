import pytest
import time
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

class TestGoogleSearch:
    """Test suite for validating UI navigation and search on Google.com across browsers."""

    def _handle_consent_dialog(self, driver):
        """Dismiss Google cookie/consent dialog if it appears."""
        try:
            # Common Google consent button texts / IDs
            consent_buttons = driver.find_elements(
                By.XPATH, 
                "//button[contains(., 'Accept all') or contains(., 'I agree') or contains(., 'Tout accepter') or contains(., 'Alle akzeptieren')]"
            )
            if consent_buttons and consent_buttons[0].is_displayed():
                consent_buttons[0].click()
                time.sleep(1)
        except Exception:
            pass

    def test_google_homepage_loads(self, driver):
        """Verify that Google homepage loads and contains the main search textarea / input."""
        driver.get("https://www.google.com")
        self._handle_consent_dialog(driver)
        
        assert "Google" in driver.title, f"Unexpected page title: {driver.title}"
        
        wait = WebDriverWait(driver, 15)
        # Google uses textarea with name 'q' or input with name 'q'
        search_box = wait.until(
            EC.presence_of_element_located((By.NAME, "q"))
        )
        assert search_box.is_displayed(), "Google search box should be visible."

    def test_google_search_query_execution(self, driver):
        """Execute a search on Google and verify that relevant result links appear."""
        driver.get("https://www.google.com")
        self._handle_consent_dialog(driver)
        
        wait = WebDriverWait(driver, 15)
        search_box = wait.until(
            EC.element_to_be_clickable((By.NAME, "q"))
        )
        
        query = "Selenium Grid on Kubernetes AKS"
        search_box.clear()
        search_box.send_keys(query)
        search_box.send_keys(Keys.RETURN)
        
        # Wait for search results container (e.g. #search or #rso)
        results = wait.until(
            EC.presence_of_element_located((By.CSS_SELECTOR, "#search, #rso"))
        )
        assert results.is_displayed(), "Google results container should be displayed."
        
        # Check that result headers exist
        headers = driver.find_elements(By.CSS_SELECTOR, "h3")
        visible_headers = [h.text for h in headers if len(h.text.strip()) > 0]
        
        assert len(visible_headers) > 0, "Expected at least one valid search result headline."
        print(f"\n[Google] First result headline ({driver.name}): {visible_headers[0]}")
