package ui;

import org.openqa.selenium.WebDriver;
import org.openqa.selenium.remote.RemoteWebDriver;
import org.openqa.selenium.remote.DesiredCapabilities;
import org.testng.Assert;
import org.testng.annotations.AfterMethod;
import org.testng.annotations.BeforeMethod;
import org.testng.annotations.Parameters;
import org.testng.annotations.Test;

import java.net.URL;
import java.time.Duration;

public class DuckTest {

    private WebDriver driver;
    private URL gridUrl;

    @BeforeMethod
    @Parameters({"browser"})
    public void setUp(String browser) throws Exception {
        // Prefer system property, then env var
        String urlProp = System.getProperty("grid.url");
        if (urlProp == null || urlProp.isBlank()) {
            urlProp = System.getProperty("GRID_URL"); // just in case code used caps
        }
        if (urlProp == null || urlProp.isBlank()) {
            urlProp = System.getenv("GRID_URL");
        }
        if (urlProp == null || urlProp.isBlank()) {
            throw new IllegalStateException(
                    "GRID URL is missing. Set -Dgrid.url or -DGRID_URL or env GRID_URL. Example: http://<public-ip>:4444");
        }

        gridUrl = new URL(urlProp);

        DesiredCapabilities caps = new DesiredCapabilities();
        // Default to chrome if no browser param given
        String b = (browser == null || browser.isBlank()) ? "chrome" : browser.toLowerCase();
        switch (b) {
            case "firefox":
                caps.setBrowserName("firefox");
                break;
            case "edge":
                caps.setBrowserName("MicrosoftEdge");
                break;
            default:
                caps.setBrowserName("chrome");
        }

        driver = new RemoteWebDriver(gridUrl, caps);
        driver.manage().timeouts().implicitlyWait(Duration.ofSeconds(10));
    }

    @AfterMethod(alwaysRun = true)
    public void tearDown() {
        if (driver != null) {
            driver.quit();
        }
    }

    @Test
    public void searchDuckDuckGoHome() {
        driver.get("https://duckduckgo.com/");
        Assert.assertTrue(driver.getTitle().toLowerCase().contains("duck"), "Title should mention Duck");
    }

    @Test
    public void openExampleDotCom() {
        driver.get("https://example.com/");
        Assert.assertTrue(driver.getTitle().toLowerCase().contains("example"), "Title should mention Example");
    }
}
