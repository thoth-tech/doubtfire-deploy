# Remediation Report: Addressing CORS Vulnerability for OnTrack Application

## **Introduction**
The OnTrack application currently has a Cross-Origin Resource Sharing (CORS) vulnerability due to the use of the `Access-Control-Allow-Origin: *` header. This configuration allows unrestricted cross-origin access, posing significant security risks.

## **Impacts**
### Unauthorized Access
Any website can interact with the API, leading to potential data leakage or abuse.

### Increased Attack Surface
Vulnerable to cross-origin attacks and malicious activities.

### Compliance Risks
Violates security and privacy standards.

## **Remediation**
### Preferred Option: Restrict `Access-Control-Allow-Origin`
- Implement a restrictive CORS policy using the `DF_ALLOWED_ORIGINS` environment variable for flexibility.
- Update backend configurations in:
  - **Docker**: `/doubtfire-api/docker-compose.yml`
  - **Rails**: `/doubtfire-api/config/application.rb`

### **Configuration Updates**
#### **Docker**
Add the following environment variable:
- DF_ALLOWED_ORIGINS: "http://localhost:4200,https://example.com"

**Note:** The `DF_ALLOWED_ORIGINS` variable must reflect the exact URLs where the OnTrack app will be accessed (e.g., production, staging, or development URLs). Failure to update this variable with the correct origins will result in inaccessibility for valid clients.

#### **Rails**
Add the following middleware configuration in `application.rb`:
config.middleware.insert_before Warden::Manager, Rack::Cors do
  allow do
    # Allowed Origins must match the URLs where the OnTrack app will be accessed.
    # Update this environment variable to prevent inaccessibility issues.
    origins ENV['DF_ALLOWED_ORIGINS'].split(',')
    resource '*', headers: :any, methods: %i[get post put delete options]
  end
end

### **Testing Plan**
#### Functional Testing:
- **Allowed Origins**: Confirm access from `http://localhost:4200`.
- **Unauthorized Origins**: Confirm access is blocked for unauthorized domains.

#### Security Testing:
- Use Postman to simulate requests with custom Origin headers.

#### Regression Testing:
- Validate that all endpoints remain functional.

### **Postman Validation Steps**
1. Create a new request in Postman.
2. Set the method (GET, POST, etc.) and endpoint.
3. Add a header:
   - **Key**: `Origin`
   - **Value**: `http://localhost:4200`
4. Observe the response for allowed and unauthorized domains.
5. Save and exit the file.  
