use super::TrackMetadata;
use crate::json::lenient_deserialize;

mod catalog;
pub use catalog::*;

#[derive(Clone, Debug, Default)]
pub struct Track {
    pub id: i64,
    pub title: String,
    pub duration: isize,
    pub track_position: isize,
    pub disk_number: isize,
    pub isrc: String,
    pub link: String,
    pub release_date: String,
    pub explicit_lyrics: Option<bool>,
    pub explicit_content_lyrics: Option<isize>,
    pub artist: Artist,
    pub album: Album,
    pub contributors: Option<Vec<Artist>>,
    /// Whether Deezer lets this release be played; absent from some
    /// responses, where it is unknown.
    pub readable: Option<bool>,
}
lenient_deserialize!(Track {
    "id" => id, "title" => title, "duration" => duration, "track_position" => track_position,
    "disk_number" => disk_number, "isrc" => isrc, "link" => link, "release_date" => release_date,
    "explicit_lyrics" => explicit_lyrics, "explicit_content_lyrics" => explicit_content_lyrics,
    "artist" => artist, "album" => album, "contributors" => contributors,
    "readable" => readable,
});

#[derive(Clone, Debug, Default)]
pub struct Artist {
    pub id: i64,
    pub name: String,
    pub picture: String,
    pub picture_medium: String,
    pub picture_big: String,
    pub picture_xl: String,
    pub nb_fan: isize,
}
lenient_deserialize!(Artist {
    "id" => id, "name" => name, "picture" => picture, "picture_medium" => picture_medium,
    "picture_big" => picture_big, "picture_xl" => picture_xl, "nb_fan" => nb_fan,
});

#[derive(Clone, Debug, Default)]
pub struct Album {
    pub id: i64,
    pub title: String,
    pub cover: String,
    pub cover_medium: String,
    pub cover_big: String,
    pub cover_xl: String,
    pub release_date: String,
    pub record_type: String,
}
lenient_deserialize!(Album {
    "id" => id, "title" => title, "cover" => cover, "cover_medium" => cover_medium,
    "cover_big" => cover_big, "cover_xl" => cover_xl, "release_date" => release_date, "record_type" => record_type,
});

#[derive(Clone, Debug, Default)]
pub struct Tracks {
    pub data: Option<Vec<Track>>,
}
lenient_deserialize!(Tracks { "data" => data, });

impl Track {
    pub fn artist_display(&self) -> String {
        match self.contributors.as_deref() {
            Some(artists) if !artists.is_empty() => artists
                .iter()
                .map(|artist| artist.name.as_str())
                .collect::<Vec<_>>()
                .join(", "),
            _ => self.artist.name.clone(),
        }
    }

    pub fn censorship(&self) -> Option<bool> {
        if self.explicit_lyrics == Some(true) || self.explicit_content_lyrics == Some(1) {
            Some(true)
        } else if self.explicit_content_lyrics == Some(0)
            || (self.explicit_lyrics == Some(false) && self.explicit_content_lyrics.is_none())
        {
            Some(false)
        } else {
            None
        }
    }

    pub fn is_explicit(&self) -> bool {
        self.censorship() == Some(true)
    }

    pub fn metadata(&self) -> TrackMetadata {
        TrackMetadata {
            spotify_id: format!("deezer:{}", self.id),
            artists: self.artist_display(),
            name: self.title.clone(),
            album_name: self.album.title.clone(),
            album_artist: self.artist.name.clone(),
            duration_ms: self.duration.wrapping_mul(1000),
            images: self.album.image(),
            release_date: if self.release_date.is_empty() {
                self.album.release_date.clone()
            } else {
                self.release_date.clone()
            },
            track_number: self.track_position,
            disc_number: self.disk_number,
            external_urls: self.link.clone(),
            isrc: self.isrc.clone(),
            album_id: format!("deezer:{}", self.album.id),
            artist_id: format!("deezer:{}", self.artist.id),
            explicit: self.censorship(),
            ..TrackMetadata::default()
        }
    }
}

pub fn best_image<'a>(images: impl IntoIterator<Item = &'a str>) -> String {
    images
        .into_iter()
        .find(|image| !image.is_empty())
        .unwrap_or_default()
        .into()
}

pub fn album_type(record_type: &str) -> String {
    if record_type == "compile" {
        "compilation"
    } else {
        record_type
    }
    .into()
}

impl Album {
    pub fn image(&self) -> String {
        best_image([
            self.cover_xl.as_str(),
            &self.cover_big,
            &self.cover_medium,
            &self.cover,
        ])
    }
}

impl Artist {
    pub fn image(&self) -> String {
        best_image([
            self.picture_xl.as_str(),
            &self.picture_big,
            &self.picture_medium,
            &self.picture,
        ])
    }
}

#[cfg(test)]
mod censorship_tests {
    use super::Track;

    #[test]
    fn public_deezer_fixture_preserves_advisory_metadata() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../../test/fixtures/track_censorship/deezer_public_20261112.json"
        ))
        .unwrap();
        let rows = fixture["responses"].as_array().unwrap();
        assert_eq!(rows.len(), 3);
        for row in rows {
            let track: Track = serde_json::from_value(row["track"].clone()).unwrap();
            let expected = row["track"]["explicit_lyrics"].as_bool();
            assert_eq!(track.censorship(), expected);
            assert_eq!(track.metadata().explicit, expected);
        }
    }

    #[test]
    fn deezer_preserves_clean_explicit_and_unknown_metadata() {
        for (json, expected) in [
            (
                r#"{"explicit_lyrics":true,"explicit_content_lyrics":1}"#,
                Some(true),
            ),
            (
                r#"{"explicit_lyrics":false,"explicit_content_lyrics":0}"#,
                Some(false),
            ),
            (
                r#"{"explicit_lyrics":false,"explicit_content_lyrics":2}"#,
                None,
            ),
            (r#"{"explicit_lyrics":false}"#, Some(false)),
            (r#"{}"#, None),
        ] {
            let track: Track = serde_json::from_str(json).unwrap();
            assert_eq!(track.censorship(), expected, "{json}");
            assert_eq!(track.metadata().explicit, expected, "{json}");
        }
    }
}
