package ui;

import org.openqa.selenium.WebDriver;
import org.openqa.selenium.remote.RemoteWebDriver;
import org.testng.Assert;
import org.testng.annotations.AfterMethod;
import org.testng.annotations.BeforeMethod;
import org.testng.annotations.Optional;
import org.testng.annotations.Parameters;

// Selenium 4 options (prefer over DesiredCapabilities)
import org.openqa.selenium.chrome.ChromeOptions;
import org.openqa.selenium.firefox.FirefoxOptions;
import org.openqa.selenium.edge.EdgeOptions;

import java.net.URL;
import java.time.Duration;

public class DuckTest {

    private WebDriver driver;

    @BeforeMethod
    @Parameters({"browser", "gridUrl"})
    public void setUp(@Optional("chrome") String browser,
                      @Optional String gridParam) throws Exception {

        // Resolve Grid URL: TestNG param -> system property -> env var
        String urlProp = firstNonBlank(
                gridParam,
                System.getProperty("grid.url"),
                System.getProperty("GRID_URL"),
                System.getenv("GRID_URL")
        );

        if (isBlank(urlProp)) {
            throw new IllegalStateException(
                    "GRID URL is missing. Provide one via TestNG parameter 'gridUrl', " +
                            "or set -Dgrid.url / -DGRID_URL, or env GRID_URL. " +
                            "Example: http://<alb-dns-or-ip>:4444"
            );
        }

        URL gridUrl = new URL(urlProp);

        // Normalize browser name
        String b = isBlank(browser) ? "chrome" : browser.trim().toLowerCase();

        // Build Selenium 4 Options (avoids deprecated DesiredCapabilities)
        switch (b) {
            case "firefox": {
                FirefoxOptions options = new FirefoxOptions();
                // options.addArguments("-headless"); // uncomment if you only run headless
                driver = new RemoteWebDriver(gridUrl, options);
                break;
            }
            case "edge": {
                EdgeOptions options = new EdgeOptions();
                driver = new RemoteWebDriver(gridUrl, options);
                break;
            }
            case "chrome":
            default: {
                ChromeOptions options = new ChromeOptions();
                // options.addArguments("--headless=new"); // uncomment if you only run headless
                driver = new RemoteWebDriver(gridUrl, options);
                break;
            }
        }

        // Basic timeouts
        driver.manage().timeouts().implicitlyWait(Duration.ofSeconds(10));
        driver.manage().timeouts().pageLoadTimeout(Duration.ofSeconds(60));
        driver.manage().timeouts().scriptTimeout(Duration.ofSeconds(30));
    }

    @AfterMethod(alwaysRun = true)
    public void tearDown() {
        if (driver != null) {
            try {
                driver.quit();
            } catch (Exception ignored) {
            }
        }
    }

    // --- Sample tests ---

    @org.testng.annotations.Test
    public void searchDuckDuckGoHome() {
        driver.get("https://duckduckgo.com/");
        Assert.assertTrue(
                driver.getTitle().toLowerCase().contains("duck"),
                "Title should mention 'duck'"
        );
    }

    @org.testng.annotations.Test
    public void openExampleDotCom() {
        driver.get("https://example.com/");
        Assert.assertTrue(
                driver.getTitle().toLowerCase().contains("example"),
                "Title should mention 'example'"
        );
    }

    // --- helpers ---

    private static boolean isBlank(String s) {
        return s == null || s.trim().isEmpty();
    }

    private static String firstNonBlank(String... values) {
        if (values == null) return null;
        for (String v : values) {
            if (!isBlank(v)) return v;
        }
        return null;
    }
}
