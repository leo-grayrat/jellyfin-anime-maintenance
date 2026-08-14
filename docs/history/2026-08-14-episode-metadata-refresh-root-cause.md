# 2026-08-14 Episode metadata refresh root-cause investigation

## Context

The unified TV audit showed that many Episodes now have correct season/episode numbers but still keep filename-derived or repeated names such as `Medalist`, `Medalist[S2`, `[FLsnow`, and `Hyakkano`.

The 243 production correction NFO files contain season/episode only. Their title and plot are blank and they contain no provider unique ids. Therefore these bad Episode names are not written by the correction NFO files.

## Important historical refresh setting

The NFO correction experiments intentionally used:

```text
metadataRefreshMode=FullRefresh
imageRefreshMode=None
replaceAllMetadata=false
replaceAllImages=false
```

This was a conservative choice for proving that Jellyfin 12 would accept the NFO season/episode correction without broadly replacing existing metadata.

## Jellyfin 12 source behavior

Current Jellyfin 12 metadata refresh code runs all metadata providers for `FullRefresh` or `ReplaceAllMetadata`.

During provider processing, local metadata can still be read unless metadata saving is enabled and `ReplaceAllMetadata` is true. The current audited TV libraries have `SaveLocalMetadata=false` and an empty `MetadataSavers` list, while the Nfo local reader remains enabled.

The decisive behavior is the final provider-result merge. Jellyfin computes replacement approximately as:

```text
shouldReplace = Full-or-higher refresh AND ReplaceAllMetadata
                OR Default refresh without ReplaceAllMetadata
```

For the historical combination `FullRefresh + replaceAllMetadata=false`, `shouldReplace` is false.

The base item merge only replaces `Name` when either:

```text
replaceData == true
```

or the existing target Name is empty. Therefore an already non-empty parser fallback such as `Medalist` is deliberately retained by this refresh mode even if a provider has a better name.

By contrast, missing Overview can be filled when the existing Overview is empty, and ProviderIds can be added without replacing all existing metadata. This matches the observed Medalist state: provider IDs, overview and image exist, while the old non-empty `Medalist` Name remains.

## Current conclusion

This is a strong source-level explanation for one important class of metadata failures:

> The earlier safe S/E repair refresh was suitable for season/episode correction, but `FullRefresh + replaceAllMetadata=false` is not a title-replacement operation. It preserves an already non-empty fallback Episode Name.

This does not yet explain every metadata problem:

- Fate/strange Fake also lacks Episode ProviderIds and Overview, so provider lookup / identity / alternate-owner behavior remains relevant there.
- 100 Girlfriends season 3 has a partially identified Series but incomplete Episode metadata, so it also needs a separate provider lookup diagnosis.

## Controlled discriminator

The next experiment is deliberately limited to Medalist S02E01, item:

```text
6993f67864a11e1151e7c9c6d3eee68d
```

This item is useful because:

- it is normally visible;
- it is already S02E01;
- its correction NFO is S02E01 with a blank title;
- it already has provider IDs, Overview and a primary image;
- its current Name is still `Medalist`.

The guarded pilot is:

```text
experiments/jellyfin12-nfo-refresh/17-medalist-e01-metadata-replace-pilot.ps1
```

Default execution is read-only preflight. `-Apply` sends exactly one Episode refresh with:

```text
metadataRefreshMode=FullRefresh
imageRefreshMode=None
replaceAllMetadata=true
replaceAllImages=false
```

Before the POST, the script refuses to proceed unless it confirms the fixed ItemId/SeriesId/S02E01 state, the sparse same-name NFO, current library metadata-saving settings, enabled Episode metadata fetchers, and absence of full/Name locks.

If the Episode Name changes while S02E01 remains intact, the historical `replaceAllMetadata=false` title-retention mechanism is experimentally confirmed. If the Name remains `Medalist`, the next discriminator is remote provider lookup / returned metadata / lock behavior rather than the sparse S/E NFO alone.

No batch metadata replacement should be attempted until this single-item result is known.
