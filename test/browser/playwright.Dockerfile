# The pinned browser runtime for the CI browser matrix. CI runs the tests inside this exact image and never
# builds this file; it exists so Dependabot can update the image together with @playwright/test.
FROM mcr.microsoft.com/playwright:v1.65.0-noble@sha256:6e3fb709361521eb27161606e6da6d2674e5e89fa16516cb37d6fdd91372273d
