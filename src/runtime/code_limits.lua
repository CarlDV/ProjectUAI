-- Shared, deliberately bounded workspace budgets (bytes, not characters).
return function()
	return { documents = 50, openViews = 10, source = 256000, versions = 12,
		versionBytes = 4 * 1024 * 1024, envelope = 12 * 1024 * 1024, actions = 50,
		proposals = 3, runs = 10, sourcePage = 6000, file = 2 * 1024 * 1024,
		inputs = 12, inputString = 4096, flushDelay = 0.8, snapshots = 20, ttl = 300000,
		sourceSnapshots = 8, sourceCacheBytes = 8 * 1024 * 1024, sourceWorkers = 4, sourceDeadline = 15000 }
end
