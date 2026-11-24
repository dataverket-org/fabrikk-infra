// Renovate's configuration for every run in the cluster. The token comes from Secret renovate/renovate.
// https://docs.renovatebot.com/self-hosted-configuration/
module.exports = {
  platform: 'forgejo',
  endpoint: 'https://git.dataverket.org/api/v1',

  // Every repository the token's user can write to, in these owners.
  autodiscover: true,
  autodiscoverFilter: ['dataverket/*'],

  // Only repositories that already have a Renovate configuration are touched,
  // and none gets an onboarding pull request.
  onboarding: false,
  requireConfig: 'required',
};
