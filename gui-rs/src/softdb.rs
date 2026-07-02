// openMSX softwaredb.xml — SHA1 → (mapper type, canonical title, system).
//
// The XML is shaped like:
//   <software title="..." system="..." company="..." year="..." >
//     <rom sha1="..." type="..." status="..." remark="..." />
//   </software>
// We only need title/system at the <software> level and sha1+type on <rom>.

use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::HashMap;

#[derive(Clone, Debug)]
pub struct Entry {
    pub mapper_type: String,
    pub title: String,
    pub system: String,
}

pub struct Softdb {
    pub by_sha1: HashMap<String, Entry>,
}

impl Softdb {
    pub fn parse(xml: &[u8]) -> Self {
        let mut reader = Reader::from_reader(xml);
        reader.config_mut().trim_text(true);
        let mut by_sha1: HashMap<String, Entry> = HashMap::new();

        let mut buf = Vec::new();
        let mut cur_title = String::new();
        let mut cur_system = String::new();

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                    let name = e.name();
                    let local = std::str::from_utf8(name.as_ref()).unwrap_or("");
                    if local == "software" {
                        cur_title.clear();
                        cur_system.clear();
                        for attr in e.attributes().flatten() {
                            let k = std::str::from_utf8(attr.key.as_ref()).unwrap_or("");
                            // Decode XML entities (&apos; &amp; &quot; &lt; &gt; and
                            // numeric refs) so titles like "Konami's Boxing" read right.
                            let v = attr.unescape_value()
                                .map(|c| c.into_owned())
                                .unwrap_or_else(|_| String::from_utf8_lossy(&attr.value).to_string());
                            if k == "title" { cur_title = v; }
                            else if k == "system" { cur_system = v; }
                        }
                    } else if local == "rom" {
                        let mut sha = String::new();
                        let mut typ = String::new();
                        let mut status = String::new();
                        for attr in e.attributes().flatten() {
                            let k = std::str::from_utf8(attr.key.as_ref()).unwrap_or("");
                            // Decode XML entities (&apos; &amp; &quot; &lt; &gt; and
                            // numeric refs) so titles like "Konami's Boxing" read right.
                            let v = attr.unescape_value()
                                .map(|c| c.into_owned())
                                .unwrap_or_else(|_| String::from_utf8_lossy(&attr.value).to_string());
                            match k {
                                "sha1" => sha = v.to_lowercase(),
                                "type" => typ = v,
                                "status" => status = v,
                                _ => {}
                            }
                        }
                        if !sha.is_empty() && !typ.is_empty() {
                            // Prefer GoodMSX when duplicates exist (mirrors Python).
                            let is_good = status == "GoodMSX";
                            match by_sha1.get(&sha) {
                                Some(_) if !is_good => {}
                                _ => {
                                    by_sha1.insert(sha, Entry {
                                        mapper_type: typ,
                                        title: cur_title.clone(),
                                        system: cur_system.clone(),
                                    });
                                }
                            }
                        }
                    }
                }
                Ok(Event::Eof) => break,
                Err(_) => break,
                _ => {}
            }
            buf.clear();
        }
        Softdb { by_sha1 }
    }

    pub fn lookup(&self, sha1: &str) -> Option<&Entry> {
        self.by_sha1.get(&sha1.to_lowercase())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_xml_entities_in_title() {
        let xml = br#"<softwaredb>
          <software title="Konami&apos;s Boxing &amp; Fun" system="MSX">
            <rom sha1="ABCDEF0123456789ABCDEF0123456789ABCDEF01" type="ASCII8" status="GoodMSX"/>
          </software>
        </softwaredb>"#;
        let db = Softdb::parse(xml);
        let e = db.lookup("abcdef0123456789abcdef0123456789abcdef01").expect("entry");
        assert_eq!(e.title, "Konami's Boxing & Fun");
    }
}

pub fn sha1_hex(data: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    let mut h = Sha1::new();
    h.update(data);
    let bytes = h.finalize();
    let mut s = String::with_capacity(40);
    for b in bytes {
        use std::fmt::Write;
        let _ = write!(s, "{:02x}", b);
    }
    s
}
