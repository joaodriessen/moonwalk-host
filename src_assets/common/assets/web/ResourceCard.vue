<template>
  <div class="card">
    <div class="card-body">
      <h2>Project and support</h2>
      <div class="d-flex flex-wrap gap-2 mt-3">
        <a class="btn btn-secondary" href="https://github.com/joaodriessen/moonwalk-host/blob/main/docs/README.md"
           target="_blank" rel="noopener noreferrer">Documentation</a>
        <a class="btn btn-secondary" :href="sourceUrl"
           target="_blank" rel="noopener noreferrer">Source code and licenses</a>
      </div>
    </div>
  </div>
</template>

<script>
const repository = 'https://github.com/joaodriessen/moonwalk-host'

export default {
  props: {
    sourceRevision: { type: String, default: '' },
  },
  computed: {
    sourceUrl() {
      return /^[a-f0-9]{40}$/.test(this.sourceRevision)
        ? repository + '/tree/' + this.sourceRevision
        : repository
    }
  }
}
</script>
