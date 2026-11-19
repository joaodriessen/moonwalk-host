// Shared submit handler for first-run setup and changes to an existing login.
export async function saveCredentials() {
  if (this.loading || this.success) return;
  this.loading = true;
  this.error = null;
  const unconfirmed = this.$t('password.save_unconfirmed');
  try {
    const response = await fetch('./api/password', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(this.passwordData),
      signal: AbortSignal.timeout(10000),
    });
    const result = await response.json();
    if (!response.ok || result?.status !== true) {
      this.error = typeof result?.error === 'string' && result.error ? result.error : unconfirmed;
      return;
    }
    this.success = true;
    this.passwordData.newPassword = '';
    this.passwordData.confirmNewPassword = '';
    if ('currentPassword' in this.passwordData) this.passwordData.currentPassword = '';
    setTimeout(() => window.location.reload(), 5000);
  } catch {
    this.error = unconfirmed;
  } finally {
    this.loading = false;
  }
}
